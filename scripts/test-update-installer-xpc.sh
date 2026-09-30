#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-Vane.app}"
: "${SIGN_ID:?Set SIGN_ID to the Vane Developer ID signing identity}"
WORK=$(mktemp -d "$HOME/Downloads/vane-installer-xpc.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/Installer Check.app"
mkdir -p "$FIXTURE/Contents/MacOS" "$FIXTURE/Contents/XPCServices"
cp -R "$APP/Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc" "$FIXTURE/Contents/XPCServices/"
xcrun swiftc Sources/Vane/UpdateInstaller.swift Tests/UpdateInstallerClient/main.swift \
  -o "$FIXTURE/Contents/MacOS/Check"
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.notnaki.vane</string>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$FIXTURE"
# Direct execution avoids registering the fixture as the user's browser in LaunchServices.
"$FIXTURE/Contents/MacOS/Check" /Applications/Vane.app
# An unrelated signed caller must fail XPC authentication before receiving a policy reply.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.notnaki.vane.installer-check' "$FIXTURE/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$FIXTURE"
"$FIXTURE/Contents/MacOS/Check" /Applications/Vane.app --unauthorized

# Exercise successful installation through the same service and engine, with only the
# allowed Applications directory injected as an isolated fixture directory. This is a
# constructor dependency, never a path the XPC caller can authorize for itself.
DESTINATION="$WORK/destination"
mkdir -p "$DESTINATION"
cat > "$WORK/main.swift" <<SWIFT
import Foundation
let service = InstallerService(applicationsDirectories: [URL(fileURLWithPath: "$DESTINATION")])
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
SWIFT
SERVICE="$FIXTURE/Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc"
xcrun swiftc -O Sources/Vane/BundleReplacement.swift Sources/Vane/UpdateVersion.swift Sources/Vane/UpdateInstaller.swift \
  Sources/UpdateInstaller/UpdateInstallation.swift Sources/UpdateInstaller/InstallerService.swift \
  "$WORK/main.swift" -o "$SERVICE/Contents/MacOS/VaneUpdateInstaller"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$SERVICE"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.notnaki.vane' "$FIXTURE/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$FIXTURE"
"$FIXTURE/Contents/MacOS/Check" /Applications/Vane.app "$DESTINATION/Vane.app" --install
codesign --verify --deep --strict "$DESTINATION/Vane.app"
