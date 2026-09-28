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
ICONSET="$WORK_ROOT/NotchShelf.iconset"
ICNS_PATH="$WORK_ROOT/NotchShelf.icns"

rm -rf "$WORK_ROOT"
mkdir -p "$ICONSET"

make_icon() {
  local size="$1"
  local output="$2"
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$output" >/dev/null
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

iconutil -c icns "$ICONSET" -o "$ICNS_PATH"

test -s "$ICNS_PATH"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$ICNS_PATH" "$APP_PATH/Contents/Resources/NotchShelf.icns"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string NotchShelf.icns' "$INFO_PLIST"

# Refresh bundle metadata before signing/packaging.
touch "$APP_PATH"

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST")"
if [[ "$ICON_NAME" != "NotchShelf.icns" ]]; then
  echo "Unexpected CFBundleIconFile: $ICON_NAME" >&2
  exit 1
fi

echo "Installed app icon: $APP_PATH/Contents/Resources/NotchShelf.icns"
