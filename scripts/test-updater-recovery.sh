#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-updater-recovery-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc Sources/Vane/BundleReplacement.swift Tests/UpdaterRecovery/main.swift -o "$WORK/check"
"$WORK/check"
