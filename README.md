# macjuice

A free, self-hosted macOS battery dashboard — the live + historical stats
coconutBattery and Battery Health charge for, built on macOS's own
`ioreg` / `pmset` / `system_profiler`. No sudo, no cloud.

## Install

    ./install.sh

This creates a venv, seeds history from `pmset -g log` (approximate — detailed
graphs begin after install), and loads a launchd agent that samples every 120s.

## Dashboard

    MACJUICE_DB="$HOME/Library/Application Support/macjuice/battery.db" \
      PYTHONPATH=macjuice macjuice/.venv/bin/python -m macjuice.app

Open http://127.0.0.1:5137

## Notes
- The collector never wakes a sleeping Mac (launchd `StartInterval`).
- Two health numbers are shown: the mAh ratio (max÷design, can exceed 100%) and
  Apple's reported Maximum Capacity %. They legitimately differ.
- `adapter_watts` is often blank when fully charged on AC — that's normal.

## Uninstall

    ./uninstall.sh

## Tests

    cd macjuice && .venv/bin/pytest
