#!/bin/bash
# Builds "DNS Pulse.app" into ./build. Run ./scripts/make_icons.sh first if you change the icon.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DNS Pulse"
EXECUTABLE="DNSPulse"
BUNDLE_ID="app.dnspulse.DNSPulse"
VERSION="1.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# Universal (Apple silicon and Intel) by default. ARCHS=arm64 ./build_app.sh builds for Apple silicon only, faster.
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "Compiling (release, $ARCHS)…"
swift build -c release --product "$EXECUTABLE" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -f Resources/Assets.car ]; then
  cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DNS Pulse tests the DNS server on your router or local network.</string>
    <key>NSHumanReadableCopyright</key>
    <string>DNS Pulse</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so the app runs locally on Apple silicon.
codesign --force --deep --sign - "$APP" >/dev/null
touch "$APP"
echo "Built $(pwd)/$APP"
