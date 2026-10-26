#!/bin/bash
# Compile and sign the probe without launching it.
set -euo pipefail
packet_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a valid local signing identity (or - for an explicitly ad-hoc diagnostic)}"
probe_linker_flags=(-framework AppKit -framework WebKit -framework Security)
case "${VANE_TEST_STAGED_WEBKIT:-0}" in
  0) ;;
  1) probe_linker_flags+=(
       -Wl,-dyld_env,DYLD_FRAMEWORK_PATH=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari
       -Wl,-dyld_env,DYLD_LIBRARY_PATH=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari) ;;
  *) echo 'VANE_TEST_STAGED_WEBKIT must be 0 or 1' >&2; exit 2 ;;
esac
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/wk-worker-ua-build.XXXXXXXX")
bundle="$output_dir/Worker UA Probe.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$packet_dir/Info.plist" "$bundle/Contents/Info.plist"
cp -R "$packet_dir/Extensions" "$bundle/Contents/Resources/Extensions"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.0 -Wall -Wextra \
  "${probe_linker_flags[@]}" \
  "$packet_dir/main.m" -o "$bundle/Contents/MacOS/WorkerUAProbe"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$packet_dir/Entitlements.plist" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
printf '%s\n' "$bundle"
