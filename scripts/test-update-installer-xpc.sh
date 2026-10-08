#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-Vane.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
: "${SIGN_ID:?Set SIGN_ID to the Vane Developer ID signing identity}"
WORK=$(mktemp -d "$HOME/Downloads/vane-installer-xpc.XXXXXX")
cleanup() {
  python3 scripts/run-updater-test-client.py "$WORK" --cleanup
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/source"
cp -R "$APP" "$WORK/source/Vane.app"
CLIENT_SOURCE="$WORK/source/Vane.app"
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
python3 scripts/run-updater-test-client.py "$WORK" -- "$FIXTURE/Contents/MacOS/Check" "$CLIENT_SOURCE"
python3 scripts/run-updater-test-client.py "$WORK" -- "$FIXTURE/Contents/MacOS/Check" "$CLIENT_SOURCE" --relaunch-rejected
# An unrelated signed caller must fail XPC authentication before receiving a policy reply.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.notnaki.vane.installer-check' "$FIXTURE/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$FIXTURE"
python3 scripts/run-updater-test-client.py "$WORK" -- "$FIXTURE/Contents/MacOS/Check" "$CLIENT_SOURCE" --unauthorized
python3 scripts/run-updater-test-client.py "$WORK" -- "$FIXTURE/Contents/MacOS/Check" "$CLIENT_SOURCE" --relaunch-rejected --unauthorized

python3 scripts/run-updater-test-client.py "$WORK" --cleanup

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
  Sources/UpdateInstaller/UpdateInstallation.swift Sources/UpdateInstaller/InstallerService.swift Sources/Vane/UpdateRelaunch.swift \
  "$WORK/main.swift" -o "$SERVICE/Contents/MacOS/VaneUpdateInstaller"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$SERVICE"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.notnaki.vane' "$FIXTURE/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$FIXTURE"
python3 scripts/run-updater-test-client.py "$WORK" -- "$FIXTURE/Contents/MacOS/Check" "$CLIENT_SOURCE" "$DESTINATION/Vane.app" --install
codesign --verify --deep --strict "$DESTINATION/Vane.app"
