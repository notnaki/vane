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
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Vane</string>
  <key>CFBundleIdentifier</key><string>com.vane.dmg-test</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Vane"
chmod +x "$APP/Contents/MacOS/Vane"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

CORRUPT_APP="$WORK/Corrupt.app"
ditto "$APP" "$CORRUPT_APP"
printf '\n# corrupted after signing\n' >> "$CORRUPT_APP/Contents/MacOS/Vane"
if "$BUILDER" "$CORRUPT_APP" "$WORK/corrupt.dmg" >"$WORK/corrupt.log" 2>&1; then
  echo "FAIL: build accepted a corrupt app signature" >&2
  exit 1
fi

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
codesign --verify --deep --strict "$MOUNT_POINT/Vane.app"
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
DS_STORE_STRINGS=$(strings -a "$MOUNT_POINT/.DS_Store")
grep -Fq "backgroundImageAlias" <<< "$DS_STORE_STRINGS"
grep -Fxq "$MOUNT_POINT" <<< "$DS_STORE_STRINGS"
grep -Fxq "/.background/background.tiff" <<< "$DS_STORE_STRINGS"

FINDER_LAYOUT=$(osascript <<'APPLESCRIPT'
tell application "Finder"
  set mountedDisk to disk "Vane"
  tell mountedDisk
    open
    tell container window
      set windowBounds to bounds
      set viewKind to current view as text
    end tell
    tell icon view options of container window
      set iconPixels to icon size
      set labelPixels to text size
    end tell
    set appPosition to position of item "Vane.app" of container window
    set applicationsPosition to position of item "Applications" of container window
    close container window
  end tell
end tell
return (item 1 of windowBounds as text) & "," & (item 2 of windowBounds as text) & "," & ¬
  (item 3 of windowBounds as text) & "," & (item 4 of windowBounds as text) & linefeed & ¬
  viewKind & linefeed & (iconPixels as text) & linefeed & (labelPixels as text) & linefeed & ¬
  (item 1 of appPosition as text) & "," & ¬
  (item 2 of appPosition as text) & linefeed & (item 1 of applicationsPosition as text) & "," & ¬
  (item 2 of applicationsPosition as text)
APPLESCRIPT
)
EXPECTED_LAYOUT=$(cat <<EOF
160,120,820,540
icon view
112
13
175,230
485,230
EOF
)
test "$FINDER_LAYOUT" = "$EXPECTED_LAYOUT"

echo "PASS: branded DMG contents and Finder layout"
