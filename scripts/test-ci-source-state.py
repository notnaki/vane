#!/usr/bin/env python3
"""Verify source timestamp restoration never hides changed inputs."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile

MODULE = Path(__file__).with_name("ci-source-state.py")
spec = importlib.util.spec_from_file_location("ci_source_state", MODULE)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source = root / "Sources/Vane/main.swift"
    source.parent.mkdir(parents=True)
    manifest = root / "Package.swift"
    source.write_text("let value = 1\n")
    manifest.write_text("// package\n")
    old = 1_700_000_000_000_000_000
    fresh = old + 10_000_000_000
    for path in (source, manifest):
        os.utime(path, ns=(old, old))
    state.save(root)

    for path in (source, manifest):
        os.utime(path, ns=(fresh, fresh))
    state.restore(root)
    assert source.stat().st_mtime_ns == old
    assert manifest.stat().st_mtime_ns == old

    source.write_text("let value = 2\n")
    os.utime(source, ns=(fresh, fresh))
    added = source.with_name("Added.swift")
    added.write_text("let added = true\n")
    os.utime(added, ns=(fresh, fresh))
    state.restore(root)
    assert source.stat().st_mtime_ns == fresh, "changed source was hidden"
    assert added.stat().st_mtime_ns == fresh, "new source was hidden"

    manifest.unlink()
    state.restore(root)  # Removed inputs are not recreated.
    assert not manifest.exists()

    snapshot = root / ".build/ci-source-state.json"
    for malformed in ([], {"Sources/Vane/main.swift": None},
                      {"Sources/Vane/main.swift": {"sha256": state.digest(source),
                                                   "mtime_ns": "invalid"}},
                      {"../../outside.swift": {"mtime_ns": old}}):
        snapshot.write_text(json.dumps(malformed))
        state.restore(root)
        assert source.stat().st_mtime_ns == fresh
    snapshot.write_text("not json")
    state.restore(root)
    assert source.stat().st_mtime_ns == fresh
    snapshot.unlink()
    state.restore(root)  # A cold cache is valid.

print("PASS: unchanged inputs keep timestamps; changed/new/removed inputs stay changed")
