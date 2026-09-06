#!/bin/bash
# Build Vane.app — a double-clickable bundle. The binary links only system frameworks
# (AppKit + WebKit), so the bundle is just: executable + Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-release}"
APP="Vane.app"
BIN=".build/$CONF/vane"

VERSION="${VANE_VERSION:-}"
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
case "$VERSION" in [0-9]*) ;; *) VERSION="0.1.0" ;; esac
BUILD="${VANE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo ">> building ($CONF)..."
swift build -c "$CONF" >/dev/null
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo ">> assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vane"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Vane</string>
  <key>CFBundleDisplayName</key>        <string>Vane</string>
  <key>CFBundleExecutable</key>         <string>Vane</string>
  <key>CFBundleIdentifier</key>         <string>io.github.notnaki.vane</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>     <string>26.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSPrincipalClass</key>           <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>  <string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>          <string>Web site URL</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>CFBundleURLSchemes</key>       <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <!-- Finder ▸ Open With ▸ Vane. Every type here is one WebKit already draws, so claiming
       it costs no code of ours; Files.swift keeps the same list. Alternate rank throughout:
       Vane offers to open a PDF, it does not take it away from Preview. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>         <string>PDF Document</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>LSHandlerRank</key>            <string>Alternate</string>
      <key>LSItemContentTypes</key>       <array><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>         <string>HTML Document</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>LSHandlerRank</key>            <string>Alternate</string>
      <key>LSItemContentTypes</key>       <array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>         <string>Image</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>LSHandlerRank</key>            <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.png</string>
        <string>public.jpeg</string>
        <string>public.svg-image</string>
        <string>com.compuserve.gif</string>
        <string>org.webmproject.webp</string>
      </array>
    </dict>
  </array>
  <key>NSCameraUsageDescription</key>     <string>Websites you visit can ask to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key> <string>Websites you visit can ask to use your microphone.</string>
  <key>NSLocationWhenInUseUsageDescription</key> <string>Websites you visit can ask for your location.</string>
</dict>
</plist>
PLIST

ENT="$(dirname "$0")/Vane.entitlements"
# The entitlements carry com.apple.security.app-sandbox, so signing is no longer cosmetic:
# an unsigned bundle is an *unsandboxed* bundle, and it would write to a different data
# directory than the sandboxed one. Fail loudly rather than shipping the wrong app.
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "$APP"
  echo "OK: signed with Developer ID ($SIGN_ID)"
else
  codesign --force --entitlements "$ENT" --sign - "$APP"
  echo "OK: signed (ad-hoc)"
fi

# Cheap proof the sandbox actually made it into the signature. codesign prints an
# "Executable=..." banner before the plist, so this greps rather than parses.
codesign -d --entitlements - --xml "$APP" 2>&1 | grep -q "com.apple.security.app-sandbox" \
  || { echo "FAIL: com.apple.security.app-sandbox is not in the signature"; exit 1; }

# Deliberately no `lsregister -f`: it force-registers whatever bundle was just built under
# the shared bundle id, so a build in a worktree would take over the user's http/https
# default and run against their real container. Launch Services registers the bundle the
# first time it is launched with `open`, which is how anyone actually runs it.
echo "OK: built $APP (sandboxed) — open with: open $APP"
