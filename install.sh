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

echo "==> Creating venv + installing deps"
[ -d "$ROOT/macjuice/.venv" ] || python3 -m venv "$ROOT/macjuice/.venv"
"$PYTHON" -m pip install -q -r "$ROOT/macjuice/requirements.txt"

echo "==> Preparing data + log dirs"
mkdir -p "$DATADIR" "$LOGDIR" "$AGENTS"
chmod 700 "$DATADIR"

echo "==> One-time history backfill"
MACJUICE_DB="$DB" PYTHONPATH="$PKGDIR" "$PYTHON" -m macjuice.backfill || true

echo "==> Generating launchd plist with absolute paths"
sed -e "s#__PYTHON__#$PYTHON#g" \
    -e "s#__DB__#$DB#g" \
    -e "s#__PKGDIR__#$PKGDIR#g" \
    -e "s#__LOGDIR__#$LOGDIR#g" \
    "$ROOT/com.macjuice.collector.plist.template" > "$PLIST"

echo "==> Loading agent"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "==> Done. Start the dashboard with:"
echo "    MACJUICE_DB=\"$DB\" PYTHONPATH=\"$PKGDIR\" \"$PYTHON\" -m macjuice.app"
echo "    then open http://127.0.0.1:5137"
