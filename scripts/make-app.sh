#!/usr/bin/env bash
# Builds build/ReviewBar.app: a menu bar app (no Dock icon), ad-hoc signed.
# Usage: scripts/make-app.sh            (then move build/ReviewBar.app to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=build/ReviewBar.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ReviewBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ReviewBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ReviewBar</string>
    <key>CFBundleIdentifier</key><string>com.github.asvartsjo.reviewbar</string>
    <key>CFBundleName</key><string>ReviewBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. No App Sandbox, since the app runs gh and claude.
codesign --force --sign - "$APP"
echo "Built $APP"
