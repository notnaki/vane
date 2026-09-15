#!/bin/bash
# Verify and exercise the exact notarized zip intended for publication, retaining evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:-}"
EVIDENCE="${2:-$PWD/release-candidate-evidence}"
[ -f "$ZIP" ] || { echo "usage: $0 Vane.zip [evidence-directory]" >&2; exit 2; }
if [ -e "$EVIDENCE" ] && [ -n "$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  echo "evidence directory is not empty: $EVIDENCE" >&2
  exit 2
fi
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vane-release-candidate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

bundle_manifest() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

root = Path(sys.argv[1])
for path in sorted([root, *root.rglob("*")], key=lambda item: os.fsencode(str(item.relative_to(root)))):
    relative = "." if path == root else str(path.relative_to(root))
    metadata = path.lstat()
    kind = ("symlink" if stat.S_ISLNK(metadata.st_mode) else
            "file" if stat.S_ISREG(metadata.st_mode) else
            "directory" if stat.S_ISDIR(metadata.st_mode) else "other")
    record = {
        "path": relative,
        "kind": kind,
        "mode": stat.S_IMODE(metadata.st_mode),
        "uid": metadata.st_uid,
        "gid": metadata.st_gid,
        "size": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "flags": getattr(metadata, "st_flags", 0),
    }
    if kind == "file":
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        record["sha256"] = digest.hexdigest()
    elif kind == "symlink":
        record["target"] = os.readlink(path)
    attributes = subprocess.run(["xattr", "-l", "-x", "-s", str(path)],
                                text=True, stdout=subprocess.PIPE, check=True).stdout
    record["xattrs"] = attributes.splitlines()
    print(json.dumps(record, sort_keys=True, separators=(",", ":")))
PY
}

shasum -a 256 "$ZIP" | tee "$EVIDENCE/SHA256SUMS"
sw_vers | tee "$EVIDENCE/system.txt"
launchctl print "gui/$(id -u)" > "$EVIDENCE/graphical-session.txt" 2>&1 \
  || { echo "no logged-in graphical session for the release check" >&2; exit 1; }
ditto -x -k "$ZIP" "$WORK"
APP="$WORK/Vane.app"
[ -d "$APP" ] || { echo "Vane.zip does not contain Vane.app" >&2; exit 1; }

bundle_manifest "$APP" > "$EVIDENCE/app-tree-before.jsonl"
{
  codesign -dvv "$APP" 2>&1
  codesign -d --entitlements - --xml "$APP" 2>&1
  xcrun stapler validate "$APP" 2>&1
  spctl --assess --type execute --verbose=4 "$APP" 2>&1
} | tee "$EVIDENCE/distribution.txt"

python3 "$ROOT/scripts/check-browser-smoke.py" --app "$APP" --distribution \
  2>&1 | tee "$EVIDENCE/browsercheck.txt"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 \
  | tee "$EVIDENCE/signature-after-smoke.txt"
bundle_manifest "$APP" > "$EVIDENCE/app-tree-after.jsonl"
cmp "$EVIDENCE/app-tree-before.jsonl" "$EVIDENCE/app-tree-after.jsonl" \
  || { echo "FAIL: app bundle changed during verification" >&2; exit 1; }
echo "PASS: release candidate verified; evidence: $EVIDENCE"
