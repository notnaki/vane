#!/bin/bash
# Compile the entire editable Icon Composer family into one native asset catalogue.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-AppIcons/Prebuilt}"
mkdir -p "$DEST"
INFO="$(mktemp -t vane-icon-info)"
trap 'rm -f "$INFO"' EXIT
SOURCES=(AppIcons/*.icon)
ALTERNATES=()
for source in "${SOURCES[@]}"; do
  name="$(basename "$source" .icon)"
  if [ "$name" != AppIcon ]; then ALTERNATES+=(--alternate-app-icon "$name"); fi
done
xcrun actool "${SOURCES[@]}" --compile "$DEST" --app-icon AppIcon \
  "${ALTERNATES[@]}" --platform macosx --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$INFO"
