#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
swiftc -swift-version 6 -parse-as-library Sources/Vane/CloudAI.swift Sources/Vane/AIConnections.swift Tests/AIConnectionsHarness.swift -o "$fixture/check"
"$fixture/check"
