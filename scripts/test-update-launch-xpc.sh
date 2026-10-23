#!/bin/bash
# Signed, headless XPC/browser sandbox fixtures; never starts the user's browser.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_ID:?Set SIGN_ID to the Vane Developer ID signing identity}"
WORK=$(mktemp -d "$HOME/Downloads/vane-installer-xpc.XXXXXX")
PROBE_NAME="Vane-security-check-$(uuidgen)"
SYSTEM_PROBE="/Applications/$PROBE_NAME"
USER_ROOT="$HOME/Applications"
USER_ROOT_CREATED=0
if [ ! -d "$USER_ROOT" ]; then mkdir "$USER_ROOT"; USER_ROOT_CREATED=1; fi
USER_PROBE="$USER_ROOT/$PROBE_NAME"
cleanup() {
  python3 scripts/run-updater-test-client.py "$WORK" --cleanup
  rm -rf "$WORK" "$SYSTEM_PROBE" "$USER_PROBE"
  if [ "$USER_ROOT_CREATED" = 1 ]; then rmdir "$USER_ROOT" 2>/dev/null || true; fi
}
trap cleanup EXIT
mkdir "$SYSTEM_PROBE" "$USER_PROBE"
echo -n canary > "$SYSTEM_PROBE/read"
echo -n canary > "$USER_PROBE/read"
APP="$WORK/templates/Vane.app"
SERVICE="$APP/Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc"
mkdir -p "$APP/Contents/MacOS" "$SERVICE/Contents/MacOS"
cp installer/UpdateInstaller-Info.plist "$SERVICE/Contents/Info.plist"
cat > "$WORK/main.swift" <<SWIFT
import Foundation
let service = InstallerService(applicationsDirectories: [URL(fileURLWithPath: "$WORK")])
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
SWIFT
xcrun swiftc Sources/Vane/BundleReplacement.swift Sources/Vane/UpdateVersion.swift Sources/Vane/UpdateInstaller.swift \
  Sources/UpdateInstaller/UpdateInstallation.swift Sources/UpdateInstaller/InstallerService.swift \
  "$WORK/main.swift" -o "$SERVICE/Contents/MacOS/VaneUpdateInstaller"
xcrun swiftc Sources/Vane/UpdateInstaller.swift Tests/UpdateLaunchClient/main.swift -o "$APP/Contents/MacOS/Vane"
xcrun swiftc Sources/Vane/BundleReplacement.swift Tests/UpdateLaunchDriver/main.swift -o "$WORK/install"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.notnaki.vane</string>
<key>CFBundleExecutable</key><string>Vane</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$SERVICE"
codesign --force --options runtime --timestamp --entitlements "${VANE_TEST_ENTITLEMENTS:-Vane.entitlements}" --sign "$SIGN_ID" "$APP"
python3 scripts/run-updater-test-client.py "$WORK" -- "$APP/Contents/MacOS/Vane" --access "$SYSTEM_PROBE" "$USER_PROBE"
python3 scripts/run-updater-test-client.py "$WORK" -- "$APP/Contents/MacOS/Vane" --wrong-target
cp -R "$APP" "$WORK/old.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.0.0' "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$APP"
mkdir "$WORK/healthy" "$WORK/rollback"
for SCENE in healthy rollback; do
  TARGET="$WORK/$SCENE/Vane.app"
  cp -R "$WORK/old.app" "$TARGET"
  "$WORK/install" "$APP" "$TARGET"
  if [ "$SCENE" = rollback ]; then
    python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --crash
    python3 scripts/run-updater-test-client.py "$WORK" --cleanup
    python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --rollback
    python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --recover-orphans
  else
    python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --healthy
  fi
done
mkdir "$WORK/displaced"
TARGET="$WORK/displaced/Vane.app"
cp -R "$WORK/old.app" "$TARGET"
python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --displaced "$WORK/ready" "$WORK/go" &
CLIENT=$!
for ATTEMPT in $(seq 1 200); do
  if [ -f "$WORK/ready" ]; then break; fi
  sleep 0.1
done
test -f "$WORK/ready"
"$WORK/install" "$APP" "$TARGET"
touch "$WORK/go"
wait "$CLIENT"
python3 scripts/run-updater-test-client.py "$WORK" -- "$TARGET/Contents/MacOS/Vane" --healthy
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.notnaki.vane.unrelated-test' "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Vane.entitlements --sign "$SIGN_ID" "$APP"
python3 scripts/run-updater-test-client.py "$WORK" -- "$APP/Contents/MacOS/Vane" --unauthorized
