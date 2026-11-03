#!/bin/bash
# Packs build/DNS Pulse.app into a compressed disk image whose window shows the app, an arrow and the
# Applications folder. Run ./build_app.sh first.
# Uses dmgbuild (https://github.com/dmgbuild/dmgbuild), installed on first run into build/.venv.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DNS Pulse.app"
[ -d "$APP" ] || { echo "Build the app first: ./build_app.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/DNS-Pulse-$VERSION.dmg"

VENV="build/.venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check dmgbuild
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# Without extended attributes, so nothing from this Mac goes along.
ditto --norsrc --noextattr "$APP" "$STAGING/DNS Pulse.app"

swift scripts/render_dmg_background.swift "$STAGING/art" >/dev/null
tiffutil -cathidpicheck "$STAGING/art/dmg-background.png" "$STAGING/art/dmg-background@2x.png" \
  -out "$STAGING/background.tiff" 2>/dev/null

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg_settings.py \
  -D app="$STAGING/DNS Pulse.app" -D background="$STAGING/background.tiff" -D icon=Resources/AppIcon.icns \
  "DNS Pulse" "$DMG" >/dev/null
echo "Built $(pwd)/$DMG"
