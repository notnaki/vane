#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-"$ROOT/Vane.app"}
OUTPUT=${2:-"$ROOT/Vane.dmg"}
BACKGROUND="$ROOT/installer/dmg-background.svg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-dmg.XXXXXX")
MOUNT_POINT=""
DEVICE=""

cleanup() {
  status=$?
  if [ -n "$DEVICE" ] && hdiutil info | grep -Fq "$DEVICE"; then
    hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet || true
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi
if [ ! -f "$BACKGROUND" ]; then
  echo "error: DMG background not found: $BACKGROUND" >&2
  exit 1
fi

STAGE="$WORK/stage"
RW_IMAGE="$WORK/Vane-rw.dmg"
BUILD_VOLUME="Vane DMG $$"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Vane.app"
ln -s /Applications "$STAGE/Applications"
sips -s format png "$BACKGROUND" \
  --out "$STAGE/.background/background@2x.png" >/dev/null
sips -z 420 660 "$STAGE/.background/background@2x.png" \
  --out "$STAGE/.background/background.png" >/dev/null
tiffutil -cathidpicheck "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil create -srcfolder "$STAGE" -volname "$BUILD_VOLUME" -fs HFS+ -format UDRW \
  -ov "$RW_IMAGE" >/dev/null
ATTACH_PLIST="$WORK/attach.plist"
hdiutil attach "$RW_IMAGE" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"
MOUNT_POINT=$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"mount-point" => "\(.*\)"/\1/p' \
  | head -1)
DEVICE=$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"dev-entry" => "\(.*\)"/\1/p' \
  | head -1)

if [ -z "$MOUNT_POINT" ]; then
  echo "error: could not mount writable DMG" >&2
  exit 1
fi

osascript - "$BUILD_VOLUME" <<'APPLESCRIPT'
on run arguments
set volumeName to item 1 of arguments
tell application "Finder"
  tell disk volumeName
    open
    set backgroundFile to file ".background:background.tiff"
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set pathbar visible to false
      set sidebar width to 0
      set bounds to {160, 120, 820, 540}
    end tell
    tell icon view options of container window
      set arrangement to not arranged
      set icon size to 112
      set text size to 13
      set background picture to backgroundFile
    end tell
    set position of item "Vane.app" of container window to {175, 230}
    set position of item "Applications" of container window to {485, 230}
    update without registering applications
    delay 2
    close
  end tell
end tell
end run
APPLESCRIPT

sync
diskutil rename "$DEVICE" Vane >/dev/null
hdiutil detach "$DEVICE" -quiet
MOUNT_POINT=""
DEVICE=""

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 \
  -ov -o "$OUTPUT" >/dev/null

echo "OK: built $OUTPUT"
