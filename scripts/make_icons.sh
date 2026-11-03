#!/bin/bash
# Regenerates the app icon resources in Resources/:
#   AppIcon.icns  – classic icon for macOS 14–15
#   Assets.car    – layered Liquid Glass icon for macOS 26+ (needs Xcode 26 or newer)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/render_icon.swift "$WORK/art"

# Classic .icns
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/art/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/art/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/art/icon-1024.png" Resources/AppIcon-1024.png
echo "wrote Resources/AppIcon.icns"

# Layered Icon Composer icon, compiled into an asset catalog.
ICON="$WORK/AppIcon.icon"
mkdir -p "$ICON/Assets"
cp "$WORK"/art/layer-*.png "$ICON/Assets/"
cat > "$ICON/icon.json" <<'JSON'
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.29412,0.36078,0.98039,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "layer-label.png", "name" : "label" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "layer-globe.png", "name" : "globe" },
        { "image-name" : "layer-needle.png", "name" : "needle" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "layer-gauge.png", "name" : "gauge" }
      ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.2 }
    },
    {
      "layers" : [
        { "image-name" : "layer-background.png", "name" : "background" }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
JSON
# Keep an editable copy: open Resources/AppIcon.icon in Icon Composer to tweak the glass effects.
rm -rf Resources/AppIcon.icon
cp -R "$ICON" Resources/AppIcon.icon

if xcrun --find actool >/dev/null 2>&1; then
  mkdir -p "$WORK/compiled"
  if xcrun actool "$ICON" --compile "$WORK/compiled" --platform macosx --target-device mac \
      --minimum-deployment-target 14.0 --app-icon AppIcon \
      --output-partial-info-plist "$WORK/compiled/partial.plist" >"$WORK/actool.log" 2>&1 \
      && [ -f "$WORK/compiled/Assets.car" ]; then
    cp "$WORK/compiled/Assets.car" Resources/Assets.car
    echo "wrote Resources/Assets.car"
  else
    echo "actool could not compile the layered icon; the classic .icns will be used."
    cat "$WORK/actool.log"
  fi
fi
