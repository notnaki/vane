#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-updater-relaunch-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc Sources/Vane/UpdateInstaller.swift Sources/Vane/UpdateRelaunch.swift Tests/UpdaterRelaunch/main.swift -o "$WORK/check"
"$WORK/check"
