#!/usr/bin/env bash
set -euo pipefail
AGENTS="$HOME/Library/LaunchAgents"
for label in com.macjuice.collector com.macjuice.dashboard; do
  PLIST="$AGENTS/$label.plist"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
done
pkill -f "macjuice.app" 2>/dev/null || true
echo "Agents removed (collector + dashboard). Data kept at ~/Library/Application Support/macjuice"
echo "To delete data: rm -rf \"$HOME/Library/Application Support/macjuice\""
