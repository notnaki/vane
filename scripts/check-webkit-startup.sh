#!/bin/bash
# Exercise production registry preparation in a fresh process, before any web view exists.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/Vane/WebKitStartup.swift Tests/WebKitStartup/ColdStartHarness.swift \
  -o "$fixture/webkit-startup-check"
"$fixture/webkit-startup-check"
