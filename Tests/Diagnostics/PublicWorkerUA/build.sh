#!/bin/bash
# SOURCE ONLY: not executed during packet preparation. Does not launch the app.
set -euo pipefail
packet_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a valid local signing identity (or - for an explicitly ad-hoc diagnostic)}"
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/wk-worker-ua-build.XXXXXXXX")
bundle="$output_dir/Worker UA Probe.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$packet_dir/Info.plist" "$bundle/Contents/Info.plist"
cp -R "$packet_dir/Extensions" "$bundle/Contents/Resources/Extensions"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.0 -Wall -Wextra \
  -framework AppKit -framework WebKit "$packet_dir/main.m" -o "$bundle/Contents/MacOS/WorkerUAProbe"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$packet_dir/Entitlements.plist" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
printf '%s\n' "$bundle"
