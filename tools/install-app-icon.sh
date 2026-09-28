#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?usage: install-app-icon.sh /path/to/NotchShelf.app}"
ICON_SOURCE="${2:-NotchShelf/Branding/AppIcon.png}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon source not found: $ICON_SOURCE" >&2
  exit 1
fi

WORK_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notchshelf-app-icon"
CATALOG="$WORK_ROOT/Assets.xcassets"
APPICON="$CATALOG/AppIcon.appiconset"
PARTIAL_INFO="$WORK_ROOT/AppIcon-Info.plist"
RESOURCES="$APP_PATH/Contents/Resources"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

rm -rf "$WORK_ROOT"
mkdir -p "$APPICON" "$RESOURCES"

make_icon() {
  local size="$1"
  local output="$2"
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$APPICON/$output" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

cat > "$APPICON/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

xcrun actool \
  --compile "$RESOURCES" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --product-type com.apple.product-type.application \
  --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL_INFO" \
  "$CATALOG"

if [[ ! -s "$PARTIAL_INFO" ]]; then
  echo "actool did not generate app icon metadata." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Merge $PARTIAL_INFO" "$INFO_PLIST"

test -s "$RESOURCES/Assets.car"

ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST" 2>/dev/null || true)"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO_PLIST" 2>/dev/null || true)"

if [[ -z "$ICON_FILE" && -z "$ICON_NAME" ]]; then
  echo "Compiled app icon metadata was not merged into Info.plist." >&2
  /usr/libexec/PlistBuddy -c 'Print' "$PARTIAL_INFO" || true
  exit 1
fi

# Force Launch Services/Finder to see the finalized bundle metadata when the DMG is mounted.
touch "$INFO_PLIST"
touch "$APP_PATH"

echo "Compiled NotchShelf app icon with actool."
echo "CFBundleIconFile=${ICON_FILE:-<none>}"
echo "CFBundleIconName=${ICON_NAME:-<none>}"
find "$RESOURCES" -maxdepth 1 -type f \( -name '*.icns' -o -name 'Assets.car' \) -print
