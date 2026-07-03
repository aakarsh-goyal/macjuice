#!/bin/bash
# Build MacJuice.app (arm64, release, ad-hoc signed). --install copies it to
# /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 1>&2

APP="dist/MacJuice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacJuice "$APP/Contents/MacOS/MacJuice"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 1>&2
echo "built $APP" 1>&2

if [ "${1:-}" = "--install" ]; then
    TARGET="/Applications/MacJuice.app"
    osascript -e 'tell application "MacJuice" to quit' >/dev/null 2>&1 || true
    pkill -x MacJuice 2>/dev/null || true
    sleep 0.5
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    echo "installed $TARGET" 1>&2
    open "$TARGET"
fi
