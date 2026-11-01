#!/bin/bash
# Exercise production registry preparation in a fresh process, before any web view exists.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
# This standalone probe does not use SwiftPM's generated Clang module map.
# Compile the same production bridge and expose its actual header to Swift.
cp Sources/ExtensionResourceBridge/include/ExtensionResourceBridge.h "$fixture/"
cat > "$fixture/module.modulemap" <<'MODULE'
module ExtensionResourceBridge {
    header "ExtensionResourceBridge.h"
    export *
}
MODULE
xcrun clang -fobjc-arc -fmodules -I "$fixture" -c \
  Sources/ExtensionResourceBridge/ExtensionResourceBridge.m \
  -o "$fixture/ExtensionResourceBridge.o"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$fixture" "$fixture/ExtensionResourceBridge.o" \
  Sources/Vane/WebKitStartup.swift Tests/WebKitStartup/ColdStartHarness.swift \
  -framework WebKit -framework Foundation \
  -o "$fixture/webkit-startup-check"
"$fixture/webkit-startup-check"
