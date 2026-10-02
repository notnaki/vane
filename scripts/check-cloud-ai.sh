#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
swiftc -swift-version 6 -parse-as-library Sources/Vane/CloudAI.swift Sources/Vane/AIKeys.swift Tests/CloudAIHarness.swift -o "$fixture/cloud-ai-check"
"$fixture/cloud-ai-check" "$@"
