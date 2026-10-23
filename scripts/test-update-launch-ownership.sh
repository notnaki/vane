#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-launch-owner-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc Sources/Vane/BundleReplacement.swift Tests/UpdateLaunchOwnership/main.swift -o "$WORK/check"
"$WORK/check"
