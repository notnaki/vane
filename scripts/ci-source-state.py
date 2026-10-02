#!/usr/bin/env python3
"""Keep unchanged Swift inputs incremental across fresh CI checkouts."""

import hashlib
import json
import os
from pathlib import Path
import sys


def inputs(root):
    return [path for path in (
        root / "Package.swift", root / "Package.resolved",
        *sorted((root / "Sources").rglob("*.swift")),
    ) if path.is_file()]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(root):
    snapshot = root / ".build/ci-source-state.json"
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_text(json.dumps({
        str(path.relative_to(root)): {
            "sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns,
        } for path in inputs(root)
    }))


def restore(root):
    try:
        saved = json.loads((root / ".build/ci-source-state.json").read_text())
        if not isinstance(saved, dict):
            return
    except (OSError, ValueError):
        return  # A missing/old/corrupt cache simply builds normally.
    restored = 0
    # Iterate actual source paths, never paths supplied by the cache.
    for path in inputs(root):
        entry = saved.get(str(path.relative_to(root)))
        if not isinstance(entry, dict):
            continue
        mtime = entry.get("mtime_ns")
        if type(mtime) is not int or not 0 <= mtime < 2**63:
            continue
        if entry.get("sha256") == digest(path):
            os.utime(path, ns=(path.stat().st_atime_ns, mtime))
            restored += 1
    print(f"Restored timestamps for {restored} unchanged Swift/package inputs")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("save", "restore"):
        raise SystemExit("usage: ci-source-state.py save|restore")
    {"save": save, "restore": restore}[sys.argv[1]](Path(__file__).resolve().parents[1])
