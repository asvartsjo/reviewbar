#!/usr/bin/env bash
# Builds build/ReviewBar.app: a menu bar app (no Dock icon).
#
# Usage: scripts/make-app.sh            (then move build/ReviewBar.app to /Applications)
#
# Environment:
#   VERSION        version string for Info.plist (default 0.1.0)
#   UNIVERSAL=1    build for Apple Silicon and Intel (needs Xcode, not just the Command Line Tools)
#   SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
#                  Unset or "-" means ad-hoc: fine for your own Mac, not for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/ReviewBar.app

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ReviewBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ReviewBar"

# App icon: assets/AppIcon.png (1024x1024) -> AppIcon.icns
mkdir -p "$APP/Contents/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ReviewBar</string>
    <key>CFBundleIdentifier</key><string>com.github.asvartsjo.reviewbar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>ReviewBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>ReviewBar review page</string>
        <key>CFBundleURLSchemes</key><array><string>reviewbar</string></array>
    </dict></array>
    <key>NSAppleEventsUsageDescription</key>
    <string>ReviewBar opens Claude Code in your terminal (Terminal or iTerm2) for follow-up sessions.</string>
</dict>
</plist>
PLIST

# No App Sandbox: the app runs gh and claude. The entitlement lets "Follow up in …"
# drive Terminal or iTerm2 via AppleScript under the hardened runtime.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements scripts/ReviewBar.entitlements "$APP"
    echo "Built $APP (ad-hoc signed)"
else
    # Hardened runtime + secure timestamp: both required for notarization.
    codesign --force --options runtime --timestamp \
        --entitlements scripts/ReviewBar.entitlements --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Built $APP (signed by $SIGN_IDENTITY)"
fi
