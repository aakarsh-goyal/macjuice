#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$ROOT/macjuice/.venv/bin/python"
PKGDIR="$ROOT/macjuice"
DATADIR="$HOME/Library/Application Support/macjuice"
LOGDIR="$HOME/Library/Logs/macjuice"
DB="$DATADIR/battery.db"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/com.macjuice.collector.plist"
DASH_PLIST="$AGENTS/com.macjuice.dashboard.plist"

echo "==> Creating venv + installing deps"
[ -d "$ROOT/macjuice/.venv" ] || python3 -m venv "$ROOT/macjuice/.venv"
"$PYTHON" -m pip install -q -r "$ROOT/macjuice/requirements.txt"

echo "==> Preparing data + log dirs"
mkdir -p "$DATADIR" "$LOGDIR" "$AGENTS"
chmod 700 "$DATADIR"

echo "==> One-time history backfill"
MACJUICE_DB="$DB" PYTHONPATH="$PKGDIR" "$PYTHON" -m macjuice.backfill || true

echo "==> Generating launchd plists with absolute paths"
subst() {  # subst <template> <output>
  sed -e "s#__PYTHON__#$PYTHON#g" \
      -e "s#__DB__#$DB#g" \
      -e "s#__PKGDIR__#$PKGDIR#g" \
      -e "s#__LOGDIR__#$LOGDIR#g" \
      "$1" > "$2"
}
subst "$ROOT/com.macjuice.collector.plist.template" "$PLIST"
subst "$ROOT/com.macjuice.dashboard.plist.template" "$DASH_PLIST"

echo "==> Loading collector agent (samples every 120s)"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "==> Loading dashboard agent (auto-starts at login, keeps running)"
# free the port in case a manual dashboard is running, then load the agent
pkill -f "macjuice.app" 2>/dev/null || true
launchctl unload "$DASH_PLIST" 2>/dev/null || true
launchctl load "$DASH_PLIST"

echo "==> Done. Dashboard is running and will auto-start at login:"
echo "    http://127.0.0.1:5137"
