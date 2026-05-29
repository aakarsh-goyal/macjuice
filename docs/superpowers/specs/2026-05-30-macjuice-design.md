# macjuice — Design Spec

**Date:** 2026-05-30
**Status:** Approved (pre-implementation), revised after design review

## 1. Purpose

A lightweight, self-hosted Flask web app for macOS that shows everything
coconutBattery and Battery Health 2/3 show — including the features those apps
put behind a paywall — using only macOS's built-in, free data sources.

The core insight: the paid apps are GUIs over free macOS tools (`ioreg`,
`pmset`, `system_profiler`). Their paywalled features (history graphs,
charge/discharge rates, runtime-since-full-charge, capacity-decline trends,
per-session breakdowns) are not secret APIs — they are simply the free data
**recorded over time** into the app's own database and graphed. macjuice does
the same: a tiny background collector logs samples into SQLite, and a Flask
dashboard reads and visualizes them.

## 2. Goals & Non-Goals

### Goals
- Live battery snapshot (charge %, capacities, cycles, health, condition,
  temperature, voltage, amperage, signed watts, charging state, adapter watts,
  time remaining).
- Continuous historical tracking with graphs over time.
- Derived "paid-tier" metrics: charge/discharge rate, runtime since last full
  charge, short- and medium-term full-charge runtime estimates,
  capacity-decline trend, per-session breakdown.
- No `sudo`, no paid software, no cloud. Runs entirely on `localhost`.
- Minimal battery impact from the collector itself.

### Non-Goals (explicitly out of scope)
- Menu-bar live widget (this is a web app, not a menu-bar app).
- iOS/iPadOS device battery info (would require a Mac↔iOS bridge, not Flask).
- Per-app energy usage / `powermetrics` (requires sudo — deliberately excluded).

## 3. Feature Parity Matrix

| Feature | coconut/BH tier | macjuice |
|---|---|---|
| Live charge, capacity, cycles, condition, temp | Free | ✓ |
| Design vs full-charge capacity (mAh) | Free | ✓ |
| History graphs (charge/health/temp/watts over time) | **Paid** | ✓ |
| Charge & discharge rate (%/hr and watts) | **Paid** | ✓ |
| Runtime since last full charge | **Paid** | ✓ |
| Capacity-decline (health) trend | **Paid** | ✓ |
| Per-session breakdown | **Paid** | ✓ |
| Menu-bar live stat | Paid | ➖ out of scope |
| iOS device battery | Paid | ➖ out of scope |

## 4. Architecture

Two independent processes sharing one SQLite database.

```
┌──────────────────┐         ┌──────────────┐         ┌─────────────────┐
│ collector daemon  │ writes  │  battery.db   │  reads  │  Flask web app   │
│ (launchd, ~120s)  ├────────▶│ (SQLite, WAL) │◀────────┤  dashboard :5137 │
└────────┬──────────┘         └──────────────┘         └────────┬────────┘
         │ shells out to                                         │ also reads
         ▼                                                       ▼ live on load
   ioreg / pmset (every cycle)                            ioreg / pmset
   system_profiler (hourly only)
```

- The **collector** is always-on (macOS `launchd` LaunchAgent), so history is
  captured even when the web page is closed and across reboots.
- The **Flask app** only reads the DB plus a fresh live snapshot on page load.
  It never needs to be running for history to accumulate.
- Both processes resolve the **same canonical DB path** (see §6.0). SQLite runs
  in **WAL mode** so the daemon's writes and the app's reads never collide with
  `database is locked` errors.

## 5. Collector Battery-Cost Mitigations

The collector is designed to be effectively free in battery terms:

### 5.1 Split light vs heavy commands
- Every cycle (default **120s**): `ioreg -arn AppleSmartBattery` (~20–50 ms)
  and `pmset -g batt` (~10 ms). These provide all fast-changing values.
- **Hourly only**: `system_profiler SPPowerDataType` (~1–2 s, heavy). It
  uniquely supplies cycle count, Apple's reported Maximum Capacity %, and
  condition — values that change at most once a day. The hourly result is cached
  and merged into each light sample.

### 5.2 120s default interval (configurable)
Battery % barely moves in 60s; graphs look identical at 120s with half the
wakeups.

### 5.3 Sleep behavior (precise)
The collector takes **no power assertion**, so deep sleep is never prevented.
Using launchd `StartInterval`, the timer does not wake a sleeping Mac. If the
interval elapses during sleep, launchd **coalesces and fires once on wake**
(not zero, not many) — yielding one useful "just woke" sample and otherwise no
activity while asleep. This is the desired behavior.

Estimated cost of the light path: ~0.7 Wh/day worst case (≈1% of one charge),
in practice far less. The heavy command runs ~24×/day instead of ~720×/day.

## 6. Components

Each is small, single-purpose, and independently testable.

### 6.0 `paths.py`
Single source of truth for filesystem locations so both processes agree.
- DB default: `~/Library/Application Support/macjuice/battery.db`, overridable
  via the `MACJUICE_DB` environment variable.
- Helper creates the parent directory on first use.
The `install.sh`-generated launchd plist exports the same path, guaranteeing the
daemon and the Flask app open the identical file.

### 6.1 `sampler.py`
Pure functions that shell out to the macOS tools and parse output into a
normalized dict. No DB, no Flask.
- `read_light() -> dict` — runs `ioreg -arn AppleSmartBattery` (XML plist,
  parsed with stdlib **`plistlib`**, wrapped in `try/except` so malformed
  output degrades gracefully) plus `pmset -g batt`. Yields charge %, current/max/
  design capacity mAh, voltage, **signed** amperage, **signed** watts, charging
  state, adapter watts, time remaining.
- `read_heavy() -> dict` — parses `system_profiler SPPowerDataType` (cycle
  count, Apple reported Maximum Capacity %, condition, temperature, model/serial).
- `read(heavy_cache) -> dict` — merges a light read with the latest heavy values.
- **Internal-battery filter:** explicitly select the Mac's internal battery and
  ignore any external/UPS power source that `pmset -g batt` may also list.
- **Missing fields are normal.** Any field that fails to parse (incl.
  `adapter_watts`, which many Macs/chargers omit) returns `None` rather than
  raising. Differences across macOS versions/hardware degrade gracefully.

**Sign & unit conventions (documented because analytics depends on them):**
- `amperage_ma` is stored **signed**: negative = discharging, positive =
  charging (normalizing AppleSmartBattery's two's-complement reporting).
- `watts = voltage_v * amperage_ma / 1000`, also **signed** (negative =
  discharging). The dashboard may show `abs()` for display; analytics uses the
  sign to determine direction.

### 6.2 `store.py`
SQLite schema + insert/query helpers (stdlib `sqlite3`, no ORM). On connect:
`PRAGMA journal_mode=WAL;` and `PRAGMA synchronous=NORMAL;`.

```sql
samples(
  ts INTEGER PRIMARY KEY,        -- unix seconds
  source TEXT NOT NULL,          -- 'live' | 'backfill'
  charge_pct, current_mah, max_mah, design_mah,
  cycle_count, max_capacity_reported_pct,   -- Apple's system_profiler number
  condition, temp_c, voltage_v, amperage_ma, watts,
  charging INTEGER, adapter_watts, time_remaining_min
);
CREATE INDEX idx_samples_ts ON samples(ts);

events(
  ts INTEGER NOT NULL,
  type TEXT NOT NULL,            -- plug_in | unplug | full_charge | sleep | wake
  source TEXT NOT NULL,          -- 'live' | 'backfill'
  detail TEXT
);
CREATE INDEX idx_events_ts ON events(ts);

meta(key TEXT PRIMARY KEY, value TEXT);  -- model, serial, design capacity
```

- Helpers: `insert_sample`, `insert_event`, `query_range`, `query_events`,
  `latest`, `set_meta`/`get_meta`.
- Append-only; ~1.5 MB/year. The `ts` index keeps "all-time" range queries fast.
- **Retention (documented, not a v1 build item):** for multi-year users a
  future optional prune can downsample samples older than 30 days to hourly
  averages and `VACUUM`. Not implemented in v1 (YAGNI for a single-user local
  app); the schema/index already support it cheaply if added later.

### 6.3 `collector.py`
The daemon loop run by launchd: maintain the hourly heavy cache, do
`sampler.read()` → `store.insert_sample()` each cycle. **Also emits events** by
comparing the new sample to the previous one: a `charging` transition writes
`plug_in`/`unplug`; reaching 100% / "Fully Charged" writes `full_charge`. (sleep/
wake events come from backfill of `pmset -g log`.) Logs and skips on transient
failure rather than crashing.

### 6.4 `backfill.py`
One-time, idempotent: parse `pmset -g log` to seed older `samples` (charge %,
sleep/wake) and `events` (sleep/wake/charge) so graphs are not empty on first
run. All seeded rows carry `source='backfill'` so the dashboard can render them
visually distinct (e.g. dashed/greyed) — the join must never look like real
high-resolution data. The available log window is short and format varies by
macOS version; backfill is explicitly **approximate**, and the README/dashboard
state that detailed graphs begin after installation.

### 6.5 `analytics.py`
Pure functions deriving the "paid" insights from raw rows. Precise definitions:

- **Two health numbers, shown side by side, never conflated:**
  - `health_capacity_pct = full_charge_capacity / design_capacity * 100`
    (the coconut-style mAh ratio).
  - `health_reported_pct` = Apple's `system_profiler` Maximum Capacity %
    (derived differently by Apple; this is what users compare against coconut).
  The "capacity-decline trend" graph trends `health_capacity_pct` over time.
  The term "battery age" is avoided internally.
- `discharge_rate(rows)` / `charge_rate(rows)` — %/hr and watts, using the
  signed-watts direction.
- `runtime_since_full_charge(rows, events)` — wall-clock elapsed + % consumed
  since the last `full_charge` event.
- `estimated_full_runtime(rows)` — returns **two** figures to avoid wild swings:
  a short-term estimate (last ~15–30 min discharge rate) and a medium-term
  estimate (last ~2–4 hr). Both exposed; the UI labels them.
- `sessions(rows, events)` — segmented by **charging↔discharging transitions**
  from the `events`/`charging` flag, not by charge %:
  - discharge session starts on charging→discharging, ends on
    discharging→charging;
  - a sleep gap (no samples for > a threshold, e.g. 10 min) is treated as an
    interruption **within** a session, not an end, as long as no charge occurred;
  - sessions shorter than a minimum duration (e.g. 2 min) and momentary
    plug/unplug blips below threshold are ignored;
  - each session reports duration, % used, and avg watts.

### 6.6 `app.py` (Flask)
Binds to `127.0.0.1:5137` (port configurable). Routes:
- `/` — dashboard HTML.
- `/api/live` — fresh `sampler.read()` snapshot, with a `sampled_at` timestamp.
- `/api/history?range=24h|7d|30d|all` — downsampled series; rows include
  `source` so the client can style backfilled points differently.
- `/api/events` — events for graph annotations.
- `/api/sessions` — computed sessions.
- `/api/analytics` — current derived metrics (rates, runtime, both estimates,
  both health numbers).

**Freshness handling:** the live card and the chart can otherwise disagree by up
to one interval (card 81%, latest stored point 79%). The dashboard (a) appends
the `/api/live` reading client-side as the most recent chart point, and (b)
shows "last sampled X min ago" next to the chart, so the two never look broken.

### 6.7 `templates/dashboard.html` + Chart.js (CDN)
- Cards: both health numbers (labeled), cycle count, condition, temperature,
  live (signed) watts, charge %, runtime since full charge, short- and
  medium-term runtime estimates.
- Line charts: charge % over time, `health_capacity_pct` over time, watts over
  time — with event annotations (plug/unplug/full/sleep/wake) and backfilled
  rows styled distinctly.
- Sessions table.

### 6.8 `install.sh`
Answers the setup/distribution friction directly:
- create a `venv`, install Flask;
- ensure the canonical data dir (`~/Library/Application Support/macjuice/`);
- run the one-time `backfill.py`;
- **generate `com.macjuice.collector.plist`** from a template, substituting
  absolute paths (venv python, `collector.py`, `MACJUICE_DB`, `WorkingDirectory`)
  so launchd and Flask reliably find the same DB;
- `launchctl load` the agent.
An `uninstall.sh` unloads the agent and (optionally) removes the data dir.

## 7. Data Flow
Collector writes a sample (and any transition events) every ~120s, heavy fields
refreshed hourly → SQLite (WAL) → Flask reads rows + `analytics.py` computes
derived metrics on request → JSON → Chart.js renders, appending the live read as
the newest point and annotating with events.

## 8. Error Handling
- `sampler` returns `None`/partial dicts on command failure or missing fields
  (plist parse wrapped in `try/except`); collector logs and skips, dashboard
  renders "—".
- `backfill` is idempotent (no duplicate rows on re-run) and marks rows
  `source='backfill'`.
- Flask endpoints return empty/partial series rather than 500 when the DB is new
  or sparse.
- WAL + busy-timeout on connections prevents `database is locked` between the two
  processes.

## 9. Testing
Parsing and analytics are pure functions → TDD-friendly.
- Capture real output of `ioreg -a`, `pmset -g batt`, `system_profiler`,
  `pmset -g log` from this Mac as fixtures.
- Unit-test every parser in `sampler.py` (incl. plist parse, internal-battery
  filter, signed amperage/watts, missing-field cases) and every computation in
  `analytics.py` (both health numbers, rate signs, session segmentation edge
  cases — sleep gaps, blips, min-duration — and the two runtime estimates)
  against fixtures.

## 10. Stack & Layout
- Python 3, Flask, stdlib `sqlite3` (WAL) + `plistlib`, Chart.js via CDN.
- localhost only; no auth, no external network.

```
macjuice/
  paths.py
  sampler.py
  store.py
  collector.py
  backfill.py
  analytics.py
  app.py
  templates/dashboard.html
  tests/  (fixtures + unit tests)
  com.macjuice.collector.plist.template
  install.sh
  uninstall.sh
  README.md
```

## 11. Decisions Locked In
- History: full continuous tracking (background collector).
- powermetrics / per-app energy: excluded (no sudo).
- UI: clean & functional (cards + Chart.js).
- Collector: two-process via launchd; light/heavy command split; 120s default;
  no power assertion; coalesces to one sample on wake.
- SQLite in WAL mode + `ts` index; canonical DB path via `paths.py` /
  `MACJUICE_DB`.
- `source` column distinguishes live vs `pmset -g log` backfill.
- Signed amperage/watts encode charge/discharge direction.
- Two health numbers (max÷design and Apple-reported) shown separately; trend the
  former; avoid the term "battery age".
- Sessions segmented by charging↔discharging transitions with sleep-gap,
  blip, and min-duration rules; driven by an `events` table.
- Runtime estimate exposes short- and medium-term figures.
- Dashboard reconciles live snapshot vs stored history (client-side live point +
  "sampled X min ago").
- `install.sh` generates the launchd plist with absolute paths.
- Retention pruning documented but not built in v1.
