#!/bin/bash
# Exercise the production picker both without resources and with the committed catalogue.
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE="$(mktemp -d -t vane-icon-check)"
trap 'rm -rf "$FIXTURE"' EXIT
xcrun swiftc -swift-version 6 Sources/Vane/AppIcon.swift Sources/Vane/MinimizedWindowIcon.swift Sources/Vane/AppIconPersistence.swift Tests/AppIcons/MigrationHarness.swift \
  -o "$FIXTURE/Check"
"$FIXTURE/Check"
# A translocation-shaped fixture path prevents Finder stamping during selections.
BUNDLE="$FIXTURE/AppTranslocation/IconCheck.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$FIXTURE/Check" "$BUNDLE/Contents/MacOS/Check"
cp AppIcons/Prebuilt/Assets.car AppIcons/Prebuilt/AppIcon.icns "$BUNDLE/Contents/Resources/"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundleIdentifier</key><string>io.github.notnaki.vane.icon-check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
"$BUNDLE/Contents/MacOS/Check" --packaged

# Exercise on-disk persistence across separate processes in a writable fixture only.
export VANE_ICON_TEST_DOMAIN="io.github.notnaki.vane.icon-test.$(basename "$FIXTURE")"
PERSIST="$FIXTURE/Persistence.app"
cp -R "$BUNDLE" "$PERSIST"
"$PERSIST/Contents/MacOS/Check" --persistence Galaxy
"$PERSIST/Contents/MacOS/Check" --persistence verify
"$PERSIST/Contents/MacOS/Check" --persistence restore
GALAXY_STAMP=$(shasum "$PERSIST/Icon"$'\r'"/..namedfork/rsrc" | cut -d ' ' -f 1)
"$PERSIST/Contents/MacOS/Check" --persistence "Fluted Glass Dark"
"$PERSIST/Contents/MacOS/Check" --persistence verify
"$PERSIST/Contents/MacOS/Check" --persistence Dark
"$PERSIST/Contents/MacOS/Check" --persistence verify
"$PERSIST/Contents/MacOS/Check" --persistence Candy
CANDY_STAMP=$(shasum "$PERSIST/Icon"$'\r'"/..namedfork/rsrc" | cut -d ' ' -f 1)
[ "$GALAXY_STAMP" != "$CANDY_STAMP" ] || { echo "FAIL: changing finish must replace the stamped image"; exit 1; }
"$PERSIST/Contents/MacOS/Check" --persistence verify

# The production sandbox must use the embedded helper, including ad-hoc local builds.
SANDBOX="$FIXTURE/Sandbox.app"
cp -R "$BUNDLE" "$SANDBOX"
SERVICE="$SANDBOX/Contents/XPCServices/io.github.notnaki.vane.IconService.xpc"
mkdir -p "$SERVICE/Contents/MacOS"
cp installer/IconService-Info.plist "$SERVICE/Contents/Info.plist"
xcrun swiftc -swift-version 6 Sources/Vane/AppIconPersistence.swift Sources/IconService/main.swift \
  -o "$SERVICE/Contents/MacOS/VaneIconService"
codesign --force --sign - "$SERVICE"
codesign --force --entitlements Vane.entitlements --sign - "$SANDBOX"
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence Galaxy
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence verify
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence "Fluted Glass Dark"
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence verify
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence Dark
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence verify
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence Galaxy
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence restore
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence invalid-data
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence removed-custom
"$SANDBOX/Contents/MacOS/Check" --sandboxed --persistence cleanup
"$PERSIST/Contents/MacOS/Check" --persistence cleanup
codesign --verify --deep --strict "$SANDBOX"
echo "PASS: built-in icons persist after exit, including the black Dark finish, in sandboxed and unsandboxed bundles"
