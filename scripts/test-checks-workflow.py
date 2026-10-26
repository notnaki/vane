#!/usr/bin/env python3
"""Exercise the required aggregate gate and the independent CI job boundaries."""

import itertools
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/checks.yml"


def jobs(text):
    body = text.split("\njobs:\n", 1)[1]
    starts = list(re.finditer(r"^  ([a-z][a-z0-9-]*):\n", body, re.MULTILINE))
    return {match[1]: body[match.end():starts[index + 1].start() if index + 1 < len(starts) else len(body)]
            for index, match in enumerate(starts)}


def block(section):
    lines = section.splitlines()
    start = lines.index("        run: |") + 1
    end = next((index for index in range(start, len(lines))
                if lines[index].strip() and not lines[index].startswith("          ")), len(lines))
    return "\n".join(line[10:] for line in lines[start:end])


def main():
    text = WORKFLOW.read_text()
    sections = jobs(text)
    gate = sections["checks"]
    assert re.search(r"^    if: \$\{\{ always\(\) \}\}$", gate, re.MULTILINE), "Aggregate must run after failed or skipped jobs"
    required = re.search(r"^    needs: \[([^\]]+)\]$", gate, re.MULTILINE)[1].replace(" ", "").split(",")
    assert set(required) == set(sections) - {"checks", "prune-caches"}, "Every worker must reach the gate"
    bindings = dict(re.findall(r"^          ([A-Z_]+): \$\{\{ needs\.([a-z]+)\.result \}\}$", gate, re.MULTILINE))
    assert set(bindings.values()) == set(required), "Each dependency result must be checked"
    assert "continue-on-error:" not in text, "Required checks may not ignore failure"
    for name in required:
        assert not re.search(r"^    needs:", sections[name], re.MULTILINE), f"{name} must start independently"
        assert not re.search(r"^    if:", sections[name], re.MULTILINE), f"{name} must not be conditionally skipped"
    assert "    needs: checks" in sections["prune-caches"]

    script = block(gate)
    trials = 0
    for states in itertools.product(("success", "failure", "cancelled", "skipped"), repeat=len(bindings)):
        environment = {**os.environ, **dict(zip(bindings, states))}
        result = subprocess.run(["bash", "-c", script], env=environment, capture_output=True)
        assert (result.returncode == 0) == all(state == "success" for state in states), states
        trials += 1
    for key in bindings:
        for value in ("", "unknown", "success\nsuccess", "$(exit 0)"):
            environment = {**os.environ, **dict.fromkeys(bindings, "success"), key: value}
            assert subprocess.run(["bash", "-c", script], env=environment, capture_output=True).returncode != 0
            trials += 1
        environment = {**os.environ, **dict.fromkeys(bindings, "success")}
        environment.pop(key)
        assert subprocess.run(["bash", "-c", script], env=environment, capture_output=True).returncode != 0
        trials += 1

    native = sections["native"]
    packaging = sections["packaging"]
    for section in (native, packaging):
        assert "    runs-on: macos-26" in section
        assert "uses: actions/cache/restore@v6" in section
        assert "run: python3 scripts/ci-source-state.py restore" in section
        assert "run: swift build -c debug" in section, "Always validate restored outputs"
    assert "uses: actions/cache/save@v6" in native
    assert "github.event_name == 'push' && github.ref == 'refs/heads/main'" in native
    assert "uses: actions/cache/save" not in packaging, "One writer for each debug cache"
    assert "swift build -c release" not in native + packaging
    assert "secrets." not in native + packaging
    assert "run: ./make-app.sh debug" in packaging
    assert "run: ./scripts/test-build-dmg.sh" in packaging
    assert "scripts/run-native-tests.py" not in packaging
    assert "fail-fast: false" in native, "A failed shard must not cancel the remaining coverage"
    matrix = re.search(r"^        shard: \[([^\]]+)\]$", native, re.MULTILINE)
    assert matrix and [int(value) for value in matrix[1].split(",")] == [1, 2, 3, 4]
    assert "--index \"$NATIVE_SHARD\" --count 4" in native
    assert "NATIVE_SHARD: ${{ matrix.shard }}" in native
    assert "swift test list --skip-build" in native, "Discover coverage from the built bundle"
    assert "scripts/native-test-shards.py plan" in native
    assert 'scripts/run-native-tests.py --skip-build --jobs 1' in native
    assert '--filter "$(cat "$RUNNER_TEMP/vane-native-shard.filter")"' in native
    assert "scripts/native-test-shards.py verify" in native, "Zero or incomplete execution must fail"
    assert "name: native-loop-logs-${{ matrix.shard }}" in native, "Matrix artifact names must be unique"
    assert "if: matrix.shard == 1 && github.event_name == 'push'" in native, "Keep a single cache writer"
    smoke = ROOT / "Tests/VaneTests/NativeApplicationLoopSmokeTests.swift"
    if smoke.exists() or "Owned AppKit loop preflight" in native:
        assert "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT: '1200'" in native
        assert "VANE_APPKIT_LOOP_SMOKE: '1'" in native
        assert "Native suite primary status=0; cleanup status=0" in native
        assert "Preserve native loop failure evidence\n        if: ${{ always() }}" in native
        assert native.index("Owned AppKit loop preflight") < native.index("Native regression tests")
    assert "test-checks-workflow.py" in sections["source"]
    assert "test-native-test-shards.py" in sections["source"]
    print(f"PASS: {trials} aggregate outcomes; independent jobs preserve native coverage and cache boundaries")


if __name__ == "__main__":
    main()
