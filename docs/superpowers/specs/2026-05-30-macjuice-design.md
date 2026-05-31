# macjuice — Design Spec

**Date:** 2026-05-30
**Status:** Approved (pre-implementation), revised after two design-review rounds
and verified against this Mac's real `ioreg`/`system_profiler` output

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

*Resolution note:* charge %, capacities, cycle count, temperature, voltage,
amperage and watts refresh **every cycle** (~120s) from `ioreg`. Only
**condition**, Apple's **reported Max Capacity %**, and the **Mac model name**
are hourly-resolution (from `system_profiler`). See §5.1.

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
Verified against this Mac's real `ioreg -arn AppleSmartBattery` output, the
light path already exposes far more than originally assumed:
- Every cycle (default **120s**): `ioreg -arn AppleSmartBattery` (~20–50 ms,
  plist) + `pmset -g batt` (~10 ms). Provides **CycleCount, Temperature
  (centi-°C), Voltage, signed Amperage, DesignCapacity, AppleRawMaxCapacity,
  AppleRawCurrentCapacity, FullyCharged, IsCharging, ExternalConnected,
  TimeRemaining, Serial** — i.e. charge %, capacities, cycles, temperature,
  voltage/amperage/watts, charging state, time remaining, and the mAh health
  ratio, all at full resolution.
- **Hourly only**: `system_profiler SPPowerDataType` (~1–2 s, heavy), now needed
  for **only three things** that `ioreg` does not reliably give: **condition**
  (Normal/Service), Apple's **reported Maximum Capacity %** (e.g. 91% here,
  which differs from both ioreg's unreliable `MaxCapacity=100` and the 85.4% mAh
  ratio), and the **Mac model name** (via `SPHardwareDataType`). Cached and
  merged into each light sample; the heavy-read timestamp is recorded (§6.2) so
  stale values are distinguishable from fresh.

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
  design capacity mAh, **cycle count**, **temperature** (centi-°C ÷ 100),
  voltage, **signed** amperage, **signed** watts, charging state, adapter watts,
  time remaining, serial.
- `read_heavy() -> dict` — parses `system_profiler SPPowerDataType` +
  `SPHardwareDataType` for the three remaining fields: condition, Apple-reported
  Maximum Capacity %, Mac model name.
- `read(heavy_cache) -> dict` — merges a light read with the latest heavy values.
- **Internal-battery filter:** explicitly select the Mac's internal battery and
  ignore any external/UPS power source that `pmset -g batt` may also list.
- **Missing fields are normal.** Any field that fails to parse returns `None`
  rather than raising. In particular `adapter_watts` is frequently `None` even
  when plugged in — when fully charged on AC the charge controller bypasses the
  battery, so `analytics.py` must **not** treat "plugged in + no adapter watts"
  as a fault (verified: `AdapterDetails.Watts` was `None` on this Mac).

**Sign & unit conventions (documented because analytics depends on them):**
- `amperage_ma` is stored **signed**: negative = discharging, positive =
  charging (normalizing AppleSmartBattery's two's-complement reporting).
- `watts = voltage_v * amperage_ma / 1000`, also **signed** (negative =
  discharging). The dashboard may show `abs()` for display; analytics uses the
  sign to determine direction.
- `health_capacity_pct = AppleRawMaxCapacity / DesignCapacity * 100`. This can
  read **>100%** on a fresh/early-life battery; macjuice shows the **true
  value uncapped** (matching coconutBattery), and does not clamp to 100.

### 6.2 `store.py`
SQLite schema + insert/query helpers (stdlib `sqlite3`, no ORM). On connect, in
this order: `PRAGMA journal_mode=WAL;`, `PRAGMA synchronous=NORMAL;`,
`PRAGMA busy_timeout=5000;` (so a reader briefly waits out a checkpoint/write
instead of erroring `database is locked` — §8 depends on this).

```sql
samples(
  ts INTEGER PRIMARY KEY,        -- unix seconds; IS the rowid, so it is
                                 -- already indexed — no separate index needed
  source TEXT NOT NULL,          -- 'live' | 'backfill'
  charge_pct, current_mah, max_mah, design_mah,
  cycle_count,
  max_capacity_reported_pct,     -- Apple's system_profiler number (hourly)
  condition,                     -- hourly
  heavy_ts INTEGER,              -- when the merged heavy fields were last read
  temp_c, voltage_v, amperage_ma, watts,
  charging INTEGER, adapter_watts, time_remaining_min
);

events(
  ts INTEGER NOT NULL,
  type TEXT NOT NULL,            -- plug_in | unplug | full_charge | sleep | wake
  source TEXT NOT NULL,          -- 'live' | 'backfill'
  detail TEXT
);
CREATE INDEX idx_events_ts ON events(ts);

meta(key TEXT PRIMARY KEY, value TEXT);  -- model, serial, design capacity
```

- `ts INTEGER PRIMARY KEY` **is** the SQLite rowid, so it is already the table's
  primary index — no separate `idx_samples_ts` (that would be pure waste). Only
  `events.ts` needs its own index.
- **On-wake collision:** the coalesced wake sample and a regular fire can land on
  the same unix-second. Inserts use **`INSERT OR IGNORE`** (keep the first row
  for that second); a duplicate second is harmless.
- `heavy_ts` records when condition / reported-capacity were last refreshed, so
  the dashboard and tests can tell a fresh cycle count from a ~1-hour-old cached
  one.
- Helpers: `insert_sample`, `insert_event`, `query_range`, `query_events`,
  `latest`, `set_meta`/`get_meta`.
- Append-only; ~1.5 MB/year. The rowid `ts` ordering keeps range queries fast.
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
  estimate (last ~2–4 hr). At 120s sampling a 15-min window is only ~7 samples
  (fewer right after wake), so each estimate requires a **minimum sample count**
  (e.g. ≥5 in-window samples) and returns `None` / "insufficient data" below it
  rather than a noisy flapping number. Both exposed; the UI labels them.
- `sessions(rows, events)` — segmented by **charging↔discharging transitions**
  from the `events`/`charging` flag, not by charge %:
  - discharge session starts on charging→discharging, ends on
    discharging→charging;
  - a sleep gap (no samples for > a threshold, e.g. 10 min) is treated as an
    interruption **within** a session, not an end, as long as no charge occurred;
  - sessions shorter than a minimum duration (e.g. 2 min) and momentary
    plug/unplug blips below threshold are ignored;
  - **clock-shift guard:** macOS can jump the wall clock on wake (esp. after a
    full drain). Reject negative or implausibly large `ts` deltas between
    samples/events so a session never reports negative duration or an impossible
    discharge rate — treat such a delta as a gap, not elapsed runtime.
  - each session reports duration, % used, and avg watts.

### 6.6 `app.py` (Flask)
Binds to `127.0.0.1:5137` (port configurable). Routes:
- `/` — dashboard HTML.
- `/api/live` — fresh `sampler.read()` snapshot, with a `sampled_at` timestamp.
- `/api/history?range=24h|7d|30d|all` — **downsampled in SQLite** (e.g.
  `GROUP BY ts / bucket_seconds` with `AVG(...)`) so the server never ships a
  year of 120s points (~260k) to Chart.js; bucket size scales with the range.
  Rows include `source` so the client can style backfilled points differently.
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
- `launchctl load` the agent;
- **set data-dir/file permissions** so the user account has full read/write on
  `battery.db` and its WAL siblings (`battery.db-wal`, `battery.db-shm`). Both
  processes run as the same user (LaunchAgent, not LaunchDaemon), so a sane
  `umask` is all that's required — but an unreadable `-wal` file is a classic
  cause of spurious `database is locked`, so set perms explicitly.
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
- WAL + `busy_timeout=5000` on connections prevents `database is locked` between
  the two processes (the timeout is actually set in §6.2's PRAGMAs).
- WAL creates `battery.db-wal` / `battery.db-shm` siblings; `install.sh` ensures
  the user can read/write them (§6.8) so a locked-file error can't arise from
  permissions.
- `analytics.py` treats "plugged in + `adapter_watts is None`" as normal (AC
  bypass when fully charged), never as a fault state.

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
- **Light path (ioreg, every cycle) now also provides cycle count + temperature;
  heavy path (`system_profiler`, hourly) shrinks to condition + Apple-reported
  Max Capacity % + Mac model.** `heavy_ts` records cache freshness.
- SQLite in WAL mode + `synchronous=NORMAL` + `busy_timeout=5000`; `ts` is the
  rowid (no separate samples index); `events.ts` indexed; canonical DB path via
  `paths.py` / `MACJUICE_DB`; `install.sh` sets perms on db + `-wal`/`-shm`.
- Inserts use `INSERT OR IGNORE` to absorb same-second on-wake collisions.
- `source` column distinguishes live vs `pmset -g log` backfill.
- Signed amperage/watts encode charge/discharge direction.
- Two health numbers (max÷design and Apple-reported) shown separately; trend the
  former; show it **uncapped** (>100% allowed); avoid the term "battery age".
- `adapter_watts is None` while plugged in is normal (AC bypass), not a fault.
- Sessions segmented by charging↔discharging transitions with sleep-gap, blip,
  min-duration, and **clock-shift** guards; driven by an `events` table.
- Runtime estimate exposes short- and medium-term figures, each with a minimum
  sample-count floor (else "insufficient data").
- History downsampled **in SQLite** (time-bucketed) before reaching Chart.js.
- Dashboard reconciles live snapshot vs stored history (client-side live point +
  "sampled X min ago").
- `install.sh` generates the launchd plist with absolute paths.
- Retention pruning documented but not built in v1.
