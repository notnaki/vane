#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILDER="$ROOT/scripts/build-dmg.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-dmg-test.XXXXXX")
MOUNT_POINT=""

cleanup() {
  status=$?
  if [ -n "$MOUNT_POINT" ] && mount | grep -Fq "on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

APP="$WORK/Vane.app"
DMG="$WORK/Vane.dmg"
mkdir -p "$APP/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Vane"
chmod +x "$APP/Contents/MacOS/Vane"

"$BUILDER" "$APP" "$DMG"

test -f "$DMG"
ATTACH_PLIST="$WORK/attach.plist"
hdiutil attach "$DMG" -readonly -nobrowse -plist > "$ATTACH_PLIST"
MOUNT_POINT=$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"mount-point" => "\(.*\)"/\1/p' \
  | head -1)

test "$(diskutil info -plist "$MOUNT_POINT" \
  | plutil -extract VolumeName raw -o - -)" = "Vane"
test -d "$MOUNT_POINT/Vane.app"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
test -f "$MOUNT_POINT/.background/background.png"
test "$(sips -g pixelWidth "$MOUNT_POINT/.background/background.png" \
  | awk '/pixelWidth/ { print $2 }')" = "660"
test "$(sips -g pixelHeight "$MOUNT_POINT/.background/background.png" \
  | awk '/pixelHeight/ { print $2 }')" = "420"
test -f "$MOUNT_POINT/.background/background@2x.png"
test "$(sips -g pixelWidth "$MOUNT_POINT/.background/background@2x.png" \
  | awk '/pixelWidth/ { print $2 }')" = "1320"
test "$(sips -g pixelHeight "$MOUNT_POINT/.background/background@2x.png" \
  | awk '/pixelHeight/ { print $2 }')" = "840"
test -f "$MOUNT_POINT/.background/background.tiff"
TIFF_INFO=$(tiffutil -info "$MOUNT_POINT/.background/background.tiff")
grep -Fq "Image Width: 660 Image Length: 420" <<< "$TIFF_INFO"
grep -Fq "Image Width: 1320 Image Length: 840" <<< "$TIFF_INFO"
test -f "$MOUNT_POINT/.DS_Store"

echo "PASS: branded DMG contents and Finder layout"
