# macjuice

A free, self-hosted macOS battery dashboard — the live **and** historical stats
that coconutBattery and Battery Health charge for, built entirely on macOS's own
`ioreg` / `pmset` / `system_profiler`. No paid app, no cloud, no admin rights.

The paid apps are mostly GUIs over those free tools; their "pro" features are
just the free data **recorded over time**. macjuice does the recording — and
shows it on a retro-futuristic power console.

![dashboard](https://github.com/raghavtripped/macjuice) <!-- open http://127.0.0.1:5137 after install -->

## Features

- **Live gauge** — charge %, state-aware colour (teal charging / amber
  discharging / red critical), power draw in watts, time remaining.
- **History graphs** — charge % and watts over time, with a 24H / 7D / 30D / ALL
  range selector and **plug-in / unplug / full-charge markers** on the timeline.
- **Two health numbers** — the raw mAh ratio (max÷design, can read >100% on a
  fresh battery, like coconutBattery) **and** Apple's smoothed Maximum Capacity %.
- **Derived metrics** — charge/discharge rate, runtime since last full charge,
  short- and medium-term full-charge runtime estimates, capacity-decline trend.
- **Discharge sessions** — every unplugged stretch with how much you drained.
- **In-app manual + controls** — a MANUAL drawer, plus STOP and UNINSTALL
  buttons right in the dashboard.

## Install

```sh
./install.sh
```

This creates a venv, seeds history from `pmset -g log` (approximate — detailed
graphs begin after install), and loads **two launchd agents that auto-start at
login**:

| Agent | What it does |
|-------|--------------|
| `com.macjuice.collector` | Samples the battery every 120s into SQLite. Never wakes the Mac from sleep. |
| `com.macjuice.dashboard` | Serves the web UI on `127.0.0.1:5137`, kept alive (auto-respawns). |

Then just open **http://127.0.0.1:5137** — anytime, even after a reboot.

## Using it

Everything is in the dashboard itself:

- **✦ MANUAL** — full guide (what each metric means, all the commands).
- **⏻ STOP** — turn it off now (dashboard only, or everything). Comes back at
  next login unless you uninstall.
- **✕ UNINSTALL** — remove both agents for good, optionally erasing data.

### Terminal equivalents

```sh
# check what's running
launchctl list | grep macjuice

# stop / start just the dashboard (logging keeps running)
launchctl unload ~/Library/LaunchAgents/com.macjuice.dashboard.plist
launchctl load   ~/Library/LaunchAgents/com.macjuice.dashboard.plist

# pause / resume background logging
launchctl unload ~/Library/LaunchAgents/com.macjuice.collector.plist
launchctl load   ~/Library/LaunchAgents/com.macjuice.collector.plist
```

## Update

```sh
cd ~/Projects/macjuice && git pull && ./install.sh   # safe to re-run anytime
```

## Uninstall

```sh
./uninstall.sh                                            # removes both agents, keeps data
rm -rf "$HOME/Library/Application Support/macjuice"      # also erase recorded data
```

## Where things live

| | Path |
|--|--|
| Code | `~/Projects/macjuice` |
| Database | `~/Library/Application Support/macjuice/battery.db` |
| Logs | `~/Library/Logs/macjuice/` |
| Agents | `~/Library/LaunchAgents/com.macjuice.{collector,dashboard}.plist` |

## How it works

```
collector agent ──writes──▶  battery.db (SQLite, WAL)  ◀──reads── dashboard agent
 ioreg/pmset (120s)                                                 Flask + Chart.js
 system_profiler (hourly)                                           127.0.0.1:5137
```

- Light reads (`ioreg` + `pmset`, ~30 ms) run every cycle; the heavy
  `system_profiler` read runs only once an hour and is cached — so the collector
  is effectively free in battery terms.
- It takes no power assertion, so it **never wakes your Mac from sleep**; you
  simply get no samples while it's asleep.
- `adapter_watts` is often blank when fully charged on AC — that's normal (the
  charge controller bypasses the battery), not a fault.

## Architecture

Pure-Python, stdlib-heavy, fully tested. Each module has one job:

| Module | Responsibility |
|--------|----------------|
| `sampler.py` | Parse `ioreg`/`pmset`/`system_profiler` into normalized samples |
| `store.py` | SQLite schema + queries (WAL, `busy_timeout`, `INSERT OR IGNORE`) |
| `analytics.py` | Pure derived metrics (health, rates, runtime, sessions) |
| `collector.py` | The 120s daemon loop + transition-event detection |
| `backfill.py` | One-time history seed from `pmset -g log` |
| `app.py` | Read-only Flask API + control endpoints |
| `templates/dashboard.html` | The Chart.js console UI |

## Tests

```sh
cd macjuice && .venv/bin/pytest
```

## License

Personal project. Built on free macOS tooling; no third-party runtime
dependencies beyond Flask.
