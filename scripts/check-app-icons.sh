#!/bin/bash
# Exercise the production picker both without resources and with the committed catalogue.
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE="$(mktemp -d -t vane-icon-check)"
trap 'rm -rf "$FIXTURE"' EXIT
xcrun swiftc -swift-version 6 Sources/Vane/AppIcon.swift Tests/AppIcons/MigrationHarness.swift \
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
