#!/usr/bin/env bash
# Packs build/ReviewBar.app into build/ReviewBar-<VERSION>.dmg with an Applications shortcut
# to drag onto. Run scripts/make-app.sh first. Signs the .dmg when SIGN_IDENTITY is a real identity.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/ReviewBar.app
DMG="build/ReviewBar-${VERSION}.dmg"
STAGING=build/dmg

[[ -d "$APP" ]] || { echo "No $APP: run scripts/make-app.sh first" >&2; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "ReviewBar ${VERSION}" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG"
