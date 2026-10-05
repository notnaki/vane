#!/bin/bash
# Build Vane.app — a double-clickable bundle. The binary links only system frameworks
# (AppKit + WebKit), with a signed XPC service for installing updates outside the sandbox.
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-release}"
APP="Vane.app"
BIN=".build/$CONF/vane"

VERSION="${VANE_VERSION:-}"
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
case "$VERSION" in [0-9]*) ;; *) VERSION="0.1.0" ;; esac
BUILD="${VANE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Local and prerelease bundles must never ask to take over the user's browser.
DEFAULT_BROWSER_PROMPT=false
if [ "$CONF" = release ] && [ -n "${SIGN_ID:-}" ] && [ "${SIGN_ID:-}" != - ] \
   && [[ "$VERSION" != *-* ]]; then
  DEFAULT_BROWSER_PROMPT=true
fi

echo ">> building ($CONF)..."
swift build -c "$CONF" >/dev/null
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo ">> building update installer..."
INSTALLER_BIN=".build/$CONF/VaneUpdateInstaller"
xcrun swiftc -O Sources/Vane/BundleReplacement.swift Sources/Vane/UpdateVersion.swift Sources/Vane/UpdateInstaller.swift \
  Sources/UpdateInstaller/UpdateInstallation.swift Sources/UpdateInstaller/InstallerService.swift \
  Sources/UpdateInstaller/main.swift -o "$INSTALLER_BIN"

echo ">> building icon persistence service..."
ICON_SERVICE_BIN=".build/$CONF/VaneIconService"
xcrun swiftc -swift-version 6 -O Sources/Vane/AppIconPersistence.swift Sources/IconService/main.swift \
  -o "$ICON_SERVICE_BIN"

echo ">> compiling app icon..."
ICONOUT="$(mktemp -d)"
# Committed renders keep builds working on hosts without the Icon Composer compiler.
# Refresh all sources with scripts/compile-app-icons.sh; see AppIcons/README.md.
if [ -f AppIcons/Prebuilt/Assets.car ] && [ -f AppIcons/Prebuilt/AppIcon.icns ]; then
  cp AppIcons/Prebuilt/AppIcon.icns AppIcons/Prebuilt/Assets.car "$ICONOUT/"
  echo ">> using pre-rendered Icon Composer assets (AppIcons/Prebuilt/)"
elif scripts/compile-app-icons.sh "$ICONOUT" >/dev/null 2>&1 \
     && [ -f "$ICONOUT/AppIcon.icns" ]; then
  echo ">> rendered all app-icon finishes (Icon Composer)"
else
  echo "  WARN: no icon assets; the bundle will use the generic app icon"
fi

echo ">> assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vane"
INSTALLER="$APP/Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc"
mkdir -p "$INSTALLER/Contents/MacOS"
cp installer/UpdateInstaller-Info.plist "$INSTALLER/Contents/Info.plist"
cp "$INSTALLER_BIN" "$INSTALLER/Contents/MacOS/VaneUpdateInstaller"
ICON_SERVICE="$APP/Contents/XPCServices/io.github.notnaki.vane.IconService.xpc"
mkdir -p "$ICON_SERVICE/Contents/MacOS"
cp installer/IconService-Info.plist "$ICON_SERVICE/Contents/Info.plist"
cp "$ICON_SERVICE_BIN" "$ICON_SERVICE/Contents/MacOS/VaneIconService"
# The Icon Composer output. Assets.car carries the Tahoe icon the system shapes itself
# (read via CFBundleIconName); the .icns is the compatibility plate. The .icns alone would
# make Tahoe draw a second squircle under an already-rounded bitmap, so both ship.
# The car holds the standard icon and all material variants — what Settings ▸ Icon's
# app-icon picker reads by name. Nothing extra goes in the Info.plist for that: macOS has no
# alternate-icon API (setAlternateIconName is UIKit's), so actool's partial plist adds only
# the CFBundleIconFile/CFBundleIconName pair already written below, and Vane switches the
# icon by assigning NSApp.applicationIconImage. See AppIcon.swift.
if [ -f "$ICONOUT/AppIcon.icns" ]; then cp "$ICONOUT/AppIcon.icns" "$APP/Contents/Resources/"; fi
if [ -f "$ICONOUT/Assets.car" ];   then cp "$ICONOUT/Assets.car"   "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Vane</string>
  <key>CFBundleDisplayName</key>        <string>Vane</string>
  <key>CFBundleExecutable</key>         <string>Vane</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>CFBundleIconName</key>           <string>AppIcon</string>
  <key>CFBundleIdentifier</key>         <string>io.github.notnaki.vane</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$BUILD</string>
  <key>VaneDefaultBrowserPromptEnabled</key> <$DEFAULT_BROWSER_PROMPT/>
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
  # Sign inside out. The installer intentionally has no App Sandbox entitlement;
  # signing it with the browser's entitlements would reproduce update quarantine.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$INSTALLER"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$ICON_SERVICE"
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "$APP"
  echo "OK: signed with Developer ID ($SIGN_ID)"
else
  codesign --force --sign - "$INSTALLER"
  codesign --force --sign - "$ICON_SERVICE"
  codesign --force --entitlements "$ENT" --sign - "$APP"
  echo "OK: signed (ad-hoc)"
fi

# Cheap proof the sandbox actually made it into the signature. codesign prints an
# "Executable=..." banner before the plist, so this greps rather than parses.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>&1)"
echo "$ENTS" | grep -q "com.apple.security.app-sandbox" \
  || { echo "FAIL: com.apple.security.app-sandbox is not in the signature"; exit 1; }
# Applications access is still required to inspect the installed version and sweep the
# displaced bundle on the next launch; publication belongs to the signed XPC installer.
echo "$ENTS" | grep -q "temporary-exception.files.absolute-path.read-write" \
  || { echo "FAIL: the /Applications exception the updater needs is not in the signature"; exit 1; }

codesign --verify --deep --strict "$APP"
INSTALLER_ENTS="$(codesign -d --entitlements - --xml "$INSTALLER" 2>&1)"
if echo "$INSTALLER_ENTS" | grep -q "com.apple.security.app-sandbox"; then
  echo "FAIL: update installer must run outside the browser sandbox"; exit 1
fi

ICON_SERVICE_ENTS="$(codesign -d --entitlements - --xml "$ICON_SERVICE" 2>&1)"
if echo "$ICON_SERVICE_ENTS" | grep -q "com.apple.security.app-sandbox"; then
  echo "FAIL: icon persistence service must run outside the browser sandbox"; exit 1
fi

# Deliberately no `lsregister -f`: it force-registers whatever bundle was just built under
# the shared bundle id, so a build in a worktree would take over the user's http/https
# default and run against their real container. Launch Services registers the bundle the
# first time it is launched with `open`, which is how anyone actually runs it.
echo "OK: built $APP (sandboxed) — open with: open $APP"
