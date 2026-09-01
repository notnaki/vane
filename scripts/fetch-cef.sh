#!/bin/bash
# Fetch a CEF (Chromium Embedded Framework) binary distribution for macOS arm64
# into vendor/cef/. This IS the update mechanism: re-run it and you get whatever
# is newest on the Spotify CDN today; the resolved version lands in .cef-version.
#
#   scripts/fetch-cef.sh              # newest stable
#   scripts/fetch-cef.sh beta         # newest beta
#   scripts/fetch-cef.sh 151.3.24+g2384915+chromium-151.0.7922.174   # pin exactly
set -euo pipefail
cd "$(dirname "$0")/.."
WANT="${1:-stable}"
INDEX="https://cef-builds.spotifycdn.com/index.json"

echo ">> resolving CEF ($WANT) for macosarm64..."
read -r VERSION FILE SHA < <(curl -fsSL "$INDEX" | python3 -c '
import json,sys
want=sys.argv[1]
vs=json.load(sys.stdin)["macosarm64"]["versions"]
def key(v): return tuple(int(x) for x in v["chromium_version"].split("."))
if want in ("stable","beta"):
    c=[v for v in vs if v["channel"]==want]
    if not c: sys.exit("no builds on channel "+want)
    v=max(c,key=key)
else:
    v=next((v for v in vs if v["cef_version"]==want), None)
    if v is None: sys.exit("no such CEF version: "+want)
f=next(f for f in v["files"] if f["type"]=="minimal")
print(v["cef_version"], f["name"], f["sha1"])
' "$WANT")

if [ -f .cef-version ] && [ "$(cat .cef-version)" = "$VERSION" ] && [ -d vendor/cef/Release ]; then
  echo "OK: already at $VERSION"; exit 0
fi

echo ">> downloading $FILE"
mkdir -p vendor
TARBALL="vendor/$FILE"
curl -fL --progress-bar "https://cef-builds.spotifycdn.com/${FILE// /%20}" -o "$TARBALL"

echo ">> verifying sha1..."
GOT=$(shasum -a 1 "$TARBALL" | cut -d' ' -f1)
[ "$GOT" = "$SHA" ] || { echo "checksum mismatch: got $GOT want $SHA"; rm -f "$TARBALL"; exit 1; }

echo ">> extracting..."
rm -rf vendor/cef vendor/_x && mkdir -p vendor/_x
tar -xjf "$TARBALL" -C vendor/_x
mv vendor/_x/* vendor/cef
rmdir vendor/_x
rm -f "$TARBALL"
echo "$VERSION" > .cef-version
echo "OK: vendor/cef is now $VERSION"
