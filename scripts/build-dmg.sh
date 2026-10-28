#!/bin/bash

set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/dmg-image.sh"
trap 'status=$?; echo "error: DMG build command failed (status $status, line $LINENO): $BASH_COMMAND" >&2' ERR
APP=${1:-"$ROOT/Vane.app"}
OUTPUT=${2:-"$ROOT/Vane.dmg"}
BACKGROUND="$ROOT/installer/dmg-background.svg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-dmg.XXXXXX")
MOUNT_POINT=""
DEVICE=""
RW_IMAGE="$WORK/Vane-rw.dmg"
ATTACH_STARTED=false

cleanup() {
  local status=$?
  trap - EXIT ERR
  if [ "$ATTACH_STARTED" = true ] && [ -z "$DEVICE" ]; then
    if DEVICE=$(dmg_image_state "$RW_IMAGE" ""); then :; else
      if [ "$?" -ne 1 ]; then
        echo "error: cannot establish DMG cleanup ownership; retaining $WORK" >&2
        if [ "$status" -eq 0 ]; then status=1; fi
        exit "$status"
      fi
    fi
  fi
  if [ -n "$DEVICE" ]; then
    if ! dmg_detach_owned "$RW_IMAGE" "$DEVICE" true; then
      echo "error: retaining DMG work directory for cleanup: $WORK" >&2
      if [ "$status" -eq 0 ]; then status=1; fi
      exit "$status"
    fi
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
if ! codesign --verify --deep --strict "$APP"; then
  echo "error: app bundle signature is invalid: $APP" >&2
  exit 1
fi

STAGE="$WORK/stage"
BUILD_VOLUME="Vane DMG $$"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Vane.app"
if ! codesign --verify --deep --strict "$STAGE/Vane.app"; then
  echo "error: staged app bundle signature is invalid" >&2
  exit 1
fi
ln -s /Applications "$STAGE/Applications"
sips -s format png "$BACKGROUND" \
  --out "$STAGE/.background/background@2x.png" >/dev/null
sips -z 420 660 "$STAGE/.background/background@2x.png" \
  --out "$STAGE/.background/background.png" >/dev/null
tiffutil -cathidpicheck "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null

echo "DMG: create writable image $RW_IMAGE" >&2
hdiutil create -srcfolder "$STAGE" -volname "$BUILD_VOLUME" -fs HFS+ -format UDRW \
  -ov "$RW_IMAGE" >/dev/null
ATTACH_PLIST="$WORK/attach.plist"
echo "DMG: attach writable image $RW_IMAGE" >&2
ATTACH_STARTED=true
hdiutil attach "$RW_IMAGE" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"
MOUNT_POINT=$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"mount-point" => "\(.*\)"/\1/p' \
  | head -1)
DEVICE=$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"dev-entry" => "\(.*\)"/\1/p' \
  | head -1)

if [ -z "$MOUNT_POINT" ] || [ -z "$DEVICE" ]; then
  echo "error: could not mount writable DMG" >&2
  exit 1
fi

echo "DMG: rename mounted volume $MOUNT_POINT ($DEVICE)" >&2
diskutil rename "$MOUNT_POINT" Vane >/dev/null
BUILD_VOLUME=Vane
FINDER_VOLUME=false
for _ in {1..50}; do
  if [ "$(osascript -e 'tell application "Finder" to exists disk "Vane"')" = "true" ]; then
    FINDER_VOLUME=true
    break
  fi
  sleep 0.1
done
if [ "$FINDER_VOLUME" != true ]; then
  echo "error: renamed DMG did not appear in Finder" >&2
  exit 1
fi

echo "DMG: apply Finder layout" >&2
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
dmg_detach_owned "$RW_IMAGE" "$DEVICE"
ATTACH_STARTED=false
MOUNT_POINT=""
DEVICE=""

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
echo "DMG: convert compressed image $OUTPUT" >&2
hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 \
  -ov -o "$OUTPUT" >/dev/null

echo "OK: built $OUTPUT"
