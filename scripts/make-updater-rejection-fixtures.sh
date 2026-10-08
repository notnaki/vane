#!/bin/bash
# Local Developer ID signatures deliberately lack matching notarization tickets.
# Input is a disposable unchanged release; output MUST be a new empty task directory.
set -euo pipefail
: "${SIGN_ID:?Set the Vane Developer ID Application signing identity}"
SOURCE="$1"
OUTPUT="$2"
[ ! -e "$OUTPUT" ] || { echo 'Output must not exist' >&2; exit 1; }
mkdir -p "$OUTPUT"
for kind in identity version architecture gatekeeper; do
  cp -R "$SOURCE" "$OUTPUT/$kind.app"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.25' "$OUTPUT/$kind.app/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.unrelated' "$OUTPUT/identity.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString invalid' "$OUTPUT/version.app/Contents/Info.plist"
case "$(uname -m)" in arm64) OTHER=x86_64 ;; *) OTHER=arm64 ;; esac
printf 'int main(void) { return 0; }\n' > "$OUTPUT/fixture.c"
xcrun clang -arch "$OTHER" "$OUTPUT/fixture.c" -o "$OUTPUT/architecture.app/Contents/MacOS/Vane"
for kind in identity version architecture gatekeeper; do
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$OUTPUT/$kind.app"
  codesign --verify --deep --strict --all-architectures "$OUTPUT/$kind.app"
done
rm "$OUTPUT/fixture.c"
