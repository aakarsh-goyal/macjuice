#!/usr/bin/env bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.macjuice.collector.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Agent removed. Data kept at ~/Library/Application Support/macjuice"
echo "To delete data: rm -rf \"$HOME/Library/Application Support/macjuice\""
