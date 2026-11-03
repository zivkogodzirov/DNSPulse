#!/bin/bash
# Packs build/DNS Pulse.app into a compressed disk image with an Applications shortcut, for release downloads.
# Run ./build_app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DNS Pulse.app"
[ -d "$APP" ] || { echo "Build the app first: ./build_app.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/DNS-Pulse-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# Without extended attributes, so nothing from this Mac goes along.
ditto --norsrc --noextattr "$APP" "$STAGING/DNS Pulse.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DNS Pulse" -srcfolder "$STAGING" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
echo "Built $(pwd)/$DMG"
