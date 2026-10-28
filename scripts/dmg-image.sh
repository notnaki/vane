#!/bin/bash

# Shared by the packager and its mounted-image integration test. Exit 0 means
# the exact image/device pair is attached, 1 means detached, 2 means uncertain.
# With an empty device, print the image's unique whole-disk device for cleanup
# after an attach failure that occurred before its output could be parsed.
dmg_image_state() {
  local information
  information=$(hdiutil info -plist) || return 2
  python3 -c '
import os, plistlib, re, sys
try:
    info = plistlib.loads(sys.stdin.buffer.read())
    image, device = os.path.realpath(sys.argv[1]), sys.argv[2]
    images = info["images"]
    owned = []
    for entry in images:
        devices = {entity["dev-entry"] for entity in entry["system-entities"] if "dev-entry" in entity}
        same_image = os.path.realpath(entry["image-path"]) == image
        if device in devices and not same_image:
            sys.exit(2)  # The device was reused by another image.
        if same_image:
            owned.append(devices)
    if not owned:
        sys.exit(1)
    if not device and len(owned) == 1:
        disks = [value for value in owned[0] if re.fullmatch(r"/dev/disk[0-9]+", value)]
        if len(disks) == 1:
            print(disks[0])
            sys.exit(0)
    sys.exit(0 if len(owned) == 1 and device and device in owned[0] else 2)
except (KeyError, TypeError, ValueError, OSError, plistlib.InvalidFileException):
    sys.exit(2)
' "$1" "$2" <<< "$information"
}

# Retry only EBUSY (16), rechecking backing-image identity before every detach.
# Force is allowed only for cleanup after failure, never to finish a build.
dmg_detach_owned() {
  local image=$1 device=$2 force=${3:-false} attempt state status
  for attempt in 1 2 3 4 5; do
    if dmg_image_state "$image" "$device"; then
      state=0
    else
      state=$?
    fi
    case "$state" in
      1) return 0 ;;
      2) echo "error: cannot verify DMG ownership: $image ($device); refusing detach" >&2; return 1 ;;
    esac
    echo "DMG: detach $image ($device), attempt $attempt" >&2
    if hdiutil detach "$device"; then
      if dmg_image_state "$image" "$device"; then
        echo "error: DMG remains attached after detach: $image ($device)" >&2
        return 1
      else
        state=$?
        if [ "$state" -eq 1 ]; then return 0; fi
        echo "error: cannot verify DMG detached: $image ($device)" >&2
        return 1
      fi
    else
      status=$?
    fi
    if [ "$status" -ne 16 ]; then return "$status"; fi
    if [ "$attempt" -lt 5 ]; then sleep 0.5; fi
  done
  if [ "$force" = true ]; then
    if dmg_image_state "$image" "$device"; then
      echo "DMG: cleanup force-detach $image ($device)" >&2
      if hdiutil detach "$device" -force; then
        if dmg_image_state "$image" "$device"; then return 1; else
          state=$?
          if [ "$state" -eq 1 ]; then return 0; fi
        fi
      fi
    fi
    echo "error: could not clean up owned DMG: $image ($device)" >&2
  fi
  return "$status"
}
