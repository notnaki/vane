#!/usr/bin/env python3
"""One staged, three-case diagnostic; never retry or change outcome deadlines."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

EXPECTED = [
    "VaneTests.NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops",
    "VaneTests.PasswordShadowAutofillTests/testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation",
    "VaneTests.PreviewLoadingPerformanceTests/testRetiredBlankNavigationAndFrameCannotMutateNewPreview",
]
PATTERN = "^(?:" + "|".join(re.escape(test) for test in EXPECTED) + ")$"
STARTED = re.compile(r"Test Case '-\[([^ ]+) ([^ ]+)\]' started\.")
FINISHED = re.compile(r"Test Case '-\[([^ ]+) ([^ ]+)\]' (passed|failed|skipped) \(")


def now():
    return datetime.now(timezone.utc).isoformat()


def report(log, status):
    started = [f"{match[1]}/{match[2]}" for match in STARTED.finditer(log)]
    completed = [{"test": f"{match[1]}/{match[2]}", "outcome": match[3]}
                 for match in FINISHED.finditer(log)]
    primary = [test for test in started if not test.startswith("VaneTests.NativeFixtureRetirementTests/")]
    outcomes = [entry for entry in completed if entry["test"] in EXPECTED]
    statuses = re.findall(r"^Native suite primary status=(-?\d+); cleanup status=(-?\d+)$", log, re.M)
    return {
        "expectedOrder": EXPECTED, "actualPrimaryOrder": primary, "completed": completed,
        "driverStatus": status, "primaryAndCleanupStatuses": statuses,
        "skips": [entry for entry in completed if entry["outcome"] == "skipped"],
        "allThreePassedWithVerifiedCleanup": status == 0 and primary == EXPECTED
        and outcomes == [{"test": test, "outcome": "passed"} for test in EXPECTED]
        and statuses == [("0", "0")]
        and not any(entry["outcome"] == "skipped" for entry in completed)
        and "AppKit loop smoke: delayedHeartbeat=true, completed=true" in log
        and not re.search(r"^\*\*\* Signal \d+: Backtracing", log, re.M),
        "interpretation": "A pass on unchanged production is NONREPRO, never a repair or required-CI clearance.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-log", type=Path, help="Inspect retained evidence without launching tests")
    parser.add_argument("--driver-status", type=int, default=0)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.verify_log:
        result = report(args.verify_log.read_text(), args.driver_status)
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 0 if result["allThreePassedWithVerifiedCleanup"] else 1

    if args.inventory is None:
        parser.error("--inventory is required for the single actual attempt")
    inventory = args.inventory.read_text().splitlines()
    selected = [test for test in inventory if re.fullmatch(PATTERN, test)]
    if selected != EXPECTED:
        raise ValueError(f"Inventory does not select the exact three cases in order: {selected}")
    temporary = output / "temporary"
    temporary.mkdir(mode=0o700)
    snapshots = output / "retirement-manifests"
    snapshots.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(temporary), VANE_APPKIT_LOOP_SMOKE="1",
                       VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT="45")
    command = [sys.executable, "scripts/run-native-tests.py", "--skip-build", "--jobs", "1", "--filter", PATTERN]
    plan = {"schema": 1, "attempts": 1, "selected": selected, "filter": PATTERN,
            "command": command, "startedUTC": now(), "primaryCapSeconds": 45,
            "cleanupCapSeconds": 90, "outcomeDeadlinesSeconds": {"shadow": 5, "preview": 8},
            "environment": {key: environment[key] for key in
                            ["TMPDIR", "VANE_APPKIT_LOOP_SMOKE", "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT"]}}
    (output / "selection.json").write_text(json.dumps(plan, indent=2) + "\n")
    log_path = output / "native.log"

    def preserve_manifests():
        # Only this attempt's private TMPDIR. Copies are evidence, never cleanup authority.
        for root in temporary.glob("vane-native-retirement-*"):
            destination = snapshots / root.name
            destination.mkdir(mode=0o700, exist_ok=True)
            for source in root.glob("*.json"):
                try:
                    shutil.copy2(source, destination / source.name)
                except FileNotFoundError:
                    pass  # The unchanged wrapper can atomically finish and remove its manifest.

    with log_path.open("w") as log:
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
        def forward(signum, _frame):
            if process.poll() is None:
                process.send_signal(signum)  # Only our unreaped direct wrapper child.
        previous = {signum: signal.signal(signum, forward) for signum in (signal.SIGINT, signal.SIGTERM)}
        try:
            while process.poll() is None:
                preserve_manifests()
                time.sleep(0.05)
            preserve_manifests()
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
    text = log_path.read_text()
    result = report(text, process.returncode)
    result.update({"wrapperPID": process.pid, "endedUTC": now(),
                   "manifestSnapshots": [str(path.relative_to(output)) for path in sorted(snapshots.rglob("*.json"))]})
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(text, end="")
    print(json.dumps(result, indent=2))
    return 0 if result["allThreePassedWithVerifiedCleanup"] else 1


if __name__ == "__main__":
    sys.exit(main())
