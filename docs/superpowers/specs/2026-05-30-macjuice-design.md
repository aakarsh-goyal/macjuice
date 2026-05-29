# macjuice — Design Spec

**Date:** 2026-05-30
**Status:** Approved (pre-implementation)

## 1. Purpose

A lightweight, self-hosted Flask web app for macOS that shows everything
coconutBattery and Battery Health 2/3 show — including the features those apps
put behind a paywall — using only macOS's built-in, free data sources.

The core insight: the paid apps are GUIs over free macOS tools (`ioreg`,
`pmset`, `system_profiler`). Their paywalled features (history graphs,
charge/discharge rates, runtime-since-full-charge, battery-age trends,
per-session breakdowns) are not secret APIs — they are simply the free data
**recorded over time** into the app's own database and graphed. macjuice does
the same: a tiny background collector logs samples into SQLite, and a Flask
dashboard reads and visualizes them.

## 2. Goals & Non-Goals

### Goals
- Live battery snapshot (charge %, capacities, cycles, health %, condition,
  temperature, voltage, amperage, live watts, charging state, adapter watts,
  time remaining).
- Continuous historical tracking with graphs over time.
- Derived "paid-tier" metrics: charge/discharge rate, runtime since last full
  charge, estimated full-charge runtime, battery-age (capacity decline) trend,
  per-session breakdown.
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
| Battery-age / capacity-decline trend | **Paid** | ✓ |
| Per-session breakdown | **Paid** | ✓ |
| Menu-bar live stat | Paid | ➖ out of scope |
| iOS device battery | Paid | ➖ out of scope |

## 4. Architecture

Two independent processes sharing one SQLite database.

```
┌──────────────────┐         ┌──────────────┐         ┌─────────────────┐
│ collector daemon  │ writes  │  battery.db   │  reads  │  Flask web app   │
│ (launchd, ~120s)  ├────────▶│   (SQLite)    │◀────────┤  dashboard :5137 │
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

## 5. Collector Battery-Cost Mitigations

The collector is designed to be effectively free in battery terms:

1. **Split light vs heavy commands.**
   - Every cycle (default **120s**): `ioreg -arn AppleSmartBattery` (~20–50 ms)
     and `pmset -g batt` (~10 ms). These provide all fast-changing values.
   - **Hourly only**: `system_profiler SPPowerDataType` (~1–2 s, heavy). It
     uniquely supplies cycle count, max-capacity health %, and condition —
     values that change at most once a day. The hourly result is cached and
     merged into each light sample.
2. **120s default interval** (configurable). Battery % barely moves in 60s;
   graphs look identical at 120s with half the wakeups.
3. **Never wakes the Mac from sleep.** Uses launchd `StartInterval`, which fires
   only when the system is already awake and is skipped during sleep. No power
   assertion is taken, so deep sleep is never prevented. Result: zero samples
   and zero cost while asleep (acceptable — nothing is being consumed by use
   then anyway).

Estimated cost of the light path: ~0.7 Wh/day worst case (≈1% of one charge),
in practice far less. The heavy command runs ~24×/day instead of ~720×/day.

## 6. Components

Each is small, single-purpose, and independently testable.

### 6.1 `sampler.py`
Pure functions that shell out to the macOS tools and parse output into a
normalized dict. No DB, no Flask.
- `read_light() -> dict` — parses `ioreg` + `pmset` (charge %, current/max/
  design capacity mAh, voltage, amperage, watts = V×A, charging state, adapter
  watts, time remaining).
- `read_heavy() -> dict` — parses `system_profiler SPPowerDataType` (cycle
  count, max-capacity health %, condition, temperature, model/serial).
- `read(heavy_cache: dict | None) -> dict` — merges a light read with the most
  recent heavy values.
- Missing/parse-failed fields return `None` rather than raising. Differences in
  macOS version or hardware degrade gracefully.

### 6.2 `store.py`
SQLite schema + insert/query helpers (stdlib `sqlite3`, no ORM).
- `samples(ts INTEGER PRIMARY KEY, charge_pct, current_mah, max_mah,
  design_mah, cycle_count, health_pct, condition, temp_c, voltage_v,
  amperage_ma, watts, charging INTEGER, adapter_watts, time_remaining_min)`.
- `meta(key, value)` — Mac model, battery serial, design capacity.
- Helpers: `insert(sample)`, `query_range(start_ts, end_ts)`, `latest()`,
  `set_meta`/`get_meta`. Append-only; ~1.5 MB/year (trivial).

### 6.3 `collector.py`
The daemon loop run by launchd: maintain hourly heavy cache, do
`sampler.read()` → `store.insert()` each cycle. Logs and skips on transient
failure rather than crashing.

### 6.4 `backfill.py`
One-time, idempotent: parse `pmset -g log` to seed older `samples` rows so
graphs are not empty on first run. Coarser than live data (charge % + sleep/
wake events only); used only to fill the past, never to overwrite live rows.

### 6.5 `analytics.py`
Pure functions deriving the "paid" insights from raw rows:
- `discharge_rate(rows)` / `charge_rate(rows)` — %/hr and watts.
- `runtime_since_full_charge(rows)` — wall-clock + % consumed since the last
  100%/"Fully Charged" event.
- `estimated_full_runtime(rows)` — extrapolate from recent discharge rate.
- `capacity_trend(rows)` — health % (max÷design) over time = battery age.
- `sessions(rows)` — segment history into sessions (continuous discharge from a
  charge event to the next plug-in) with duration, % used, avg watts.

### 6.6 `app.py` (Flask)
Routes:
- `/` — dashboard HTML.
- `/api/live` — fresh `sampler.read()` snapshot (never stale).
- `/api/history?range=24h|7d|30d|all` — downsampled series for charts.
- `/api/sessions` — computed sessions.
- `/api/analytics` — current derived metrics (rates, runtime, estimates).
Binds to `127.0.0.1:5137` only.

### 6.7 `templates/dashboard.html` + Chart.js (CDN)
- Cards: health %, cycle count, condition, temperature, live watts, charge %,
  runtime since full charge, estimated full runtime.
- Line charts: charge % over time, health % over time, watts over time.
- Sessions table.

## 7. Data Flow
Collector writes every ~120s (heavy fields refreshed hourly) → SQLite →
Flask reads rows + `analytics.py` computes derived metrics on request → JSON →
Chart.js renders. The live card region is read fresh on page load.

## 8. Error Handling
- `sampler` returns `None`/partial dicts on command failure or missing fields;
  collector logs and skips, dashboard renders "—".
- `backfill` is idempotent (no duplicate rows on re-run).
- Flask endpoints return empty series / partial data rather than 500 when the
  DB is new or sparse.

## 9. Testing
Parsing and analytics are pure functions → TDD-friendly.
- Capture real output of `ioreg`, `pmset`, `system_profiler`, `pmset -g log`
  from this Mac as fixtures.
- Unit-test every parser in `sampler.py` and every computation in
  `analytics.py` against fixtures (including missing-field cases).

## 10. Stack & Layout
- Python 3, Flask, stdlib `sqlite3` (no ORM), Chart.js via CDN.
- localhost only; no auth, no external network.

```
macjuice/
  sampler.py
  store.py
  collector.py
  backfill.py
  analytics.py
  app.py
  templates/dashboard.html
  tests/  (fixtures + unit tests)
  com.macjuice.collector.plist   (launchd LaunchAgent template)
  README.md
```

## 11. Decisions Locked In
- History: full continuous tracking (background collector).
- powermetrics / per-app energy: excluded (no sudo).
- UI: clean & functional (cards + Chart.js).
- Collector: two-process via launchd; light/heavy command split; 120s default;
  never wakes from sleep.
- Backfill from `pmset -g log` as a one-time history seed.
