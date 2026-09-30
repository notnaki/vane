#!/bin/bash
# Validate real signed/notarized copies without touching an installed Vane.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Applications/Vane.app}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vane-installer-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc Sources/Vane/BundleReplacement.swift Sources/Vane/UpdateVersion.swift Sources/Vane/UpdateInstaller.swift \
  Sources/UpdateInstaller/UpdateInstallation.swift Tests/UpdateInstaller/main.swift \
  -o "$WORK/check"
if [ "$#" -gt 0 ]; then shift; fi
"$WORK/check" "$APP" "$@"
