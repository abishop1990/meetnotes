#!/usr/bin/env bash
# Build MeetNotes.app into ~/Applications. No Xcode project needed; Command Line Tools are enough.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -vE "warning:|^\s*$|\^~" || true
BIN=".build/release/MeetNotes"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="$HOME/Applications/MeetNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp scripts/diarize.py scripts/setup-diarization.sh "$APP/Contents/Resources/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "built $APP"
