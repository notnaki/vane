#!/usr/bin/env python3
"""One exact recorded-history experiment; a pass is never a claimed repair."""
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

START = re.compile(r"Test Case '-\[([^ ]+) ([^ ]+)\]' started\.")
END = r"Test Case '-\[{} {}\]' (passed|failed|skipped) \("
SMOKE = "VaneTests.NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops"
SPEC = json.loads(Path("scripts/shadow-preview-original-prefix.json").read_text())
EXPECTED = [r["test"] for r in SPEC["expected"]]
TARGETS = set(SPEC["targets"])

def utc():
    return datetime.now(timezone.utc).isoformat()

def cases(text):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    starts = list(START.finditer(text))
    rows = []
    for i, m in enumerate(starts):
        if m[1] == "VaneTests.NativeFixtureRetirementTests":
            continue
        block = text[m.end():starts[i + 1].start() if i + 1 < len(starts) else len(text)]
        finish = re.search(END.format(re.escape(m[1]), re.escape(m[2])), block)
        reason = re.search(r"Test skipped - ([^\r\n]+)", block)
        rows.append({"test": f"{m[1]}/{m[2]}",
                     "outcome": finish[1] if finish else "incomplete",
                     "skipReason": reason[1].strip() if reason else None})
    return rows

def analyze(text, status):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    actual = cases(text)
    observed = {r["test"]: r for r in actual}
    statuses = re.findall(r"^Native suite primary status=(-?\d+); cleanup status=(-?\d+)$", text, re.M)
    order_matches = [r["test"] for r in actual] == EXPECTED
    other_mismatches = [
        {"expected": r, "actual": observed.get(r["test"])}
        for r in SPEC["expected"]
        if r["test"] not in TARGETS and observed.get(r["test"]) != r
    ]
    cleanup_verified = len(statuses) == 1 and statuses[0][1] == "0"
    fatal = bool(re.search(r"\*\*\* Signal \d+: Backtracing", text))
    targets = [observed.get(t, {"test": t, "outcome": "missing"}) for t in SPEC["targets"]]
    skipped_match = ([r for r in actual if r["outcome"] == "skipped"]
                     == [r for r in SPEC["expected"] if r["outcome"] == "skipped"])
    driver_contract = len(statuses) == 1 and (
        (status == 0 and statuses[0] == ("0", "0")) or
        (status == 1 and statuses[0] == ("1", "0")))
    matched = (order_matches and not other_mismatches and skipped_match
               and cleanup_verified and driver_contract and not fatal)
    all_pass = matched and status == 0 and statuses == [("0", "0")] and all(r["outcome"] == "passed" for r in targets)
    return {"expectedCount": len(EXPECTED), "actualCount": len(actual),
            "exactOrder": order_matches, "skipReasonsMatch": skipped_match,
            "driverContract": driver_contract, "nonTargetMismatches": other_mismatches,
            "primaryAndCleanup": statuses, "driverStatus": status, "fatalSignal": fatal,
            "matchedRecordedHistory": matched, "targets": targets, "allPassed": all_pass,
            "interpretation": "NONREPRO only if targets pass; failures require staged evidence. No repair or required-CI clearance is inferred.",
            "actual": actual}

def run_phase(name, selected, primary_cap, smoke, output):
    temporary = output / f"temporary-{name}"
    temporary.mkdir(mode=0o700)
    snapshots = output / "retirement-manifests" / name
    snapshots.mkdir(parents=True, mode=0o700)
    env = os.environ.copy()
    env["TMPDIR"] = str(temporary)
    env["VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT"] = str(primary_cap)
    env.pop("VANE_APPKIT_LOOP_SMOKE", None)
    if smoke:
        env["VANE_APPKIT_LOOP_SMOKE"] = "1"
    env["SWIFT_BACKTRACE"] = "enable=yes,interactive=no,color=no,threads=crashed,registers=none,images=none,limit=48,top=0,sanitize=yes,output-to=stderr,timeout=10s,warnings=suppressed"
    pattern = "^(?:" + "|".join(re.escape(t) for t in selected) + ")$"
    command = [sys.executable, "scripts/run-native-tests.py", "--skip-build", "--jobs", "1", "--filter", pattern]
    seen = {}
    def snapshot():
        for directory in temporary.glob("vane-native-retirement-*"):
            for source in directory.glob("*.json"):
                try:
                    if source.is_symlink() or not source.resolve().is_relative_to(temporary):
                        continue
                    stat = source.stat()
                    key = (stat.st_mtime_ns, stat.st_size)
                    if seen.get(str(source)) == key:
                        continue
                    target = snapshots / directory.name
                    target.mkdir(mode=0o700, exist_ok=True)
                    shutil.copy2(source, target / source.name)
                    seen[str(source)] = key
                except FileNotFoundError:
                    pass
    log_path = output / f"{name}.log"
    began = utc()
    with log_path.open("w") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        def forward(signum, _frame):
            if process.poll() is None:
                process.send_signal(signum)  # Only the unreaped direct wrapper child.
        previous = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            while process.poll() is None:
                snapshot()
                time.sleep(0.2)
            snapshot()
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)
    text = log_path.read_text()
    print(text, end="", flush=True)
    return text, process.returncode, {"startedUTC": began, "endedUTC": utc(),
                                     "wrapperPID": process.pid, "driverStatus": process.returncode,
                                     "primaryCap": primary_cap, "cleanupCap": 90}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-log", type=Path)
    parser.add_argument("--driver-status", type=int, default=0)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.verify_log:
        report = analyze(args.verify_log.read_text(), args.driver_status)
        (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: v for k, v in report.items() if k != "actual"}, indent=2))
        return 0 if report["matchedRecordedHistory"] else 1
    if args.inventory is None:
        parser.error("--inventory is required")
    inventory = args.inventory.read_text().splitlines()
    selected = [t for t in inventory if t in set(EXPECTED)]
    if selected != EXPECTED or SMOKE not in inventory:
        raise ValueError("Compiled inventory/order differs from the recorded 469-case prefix")
    plan = {"head": os.environ.get("GITHUB_SHA"), "originalHead": SPEC["originalHead"],
            "originalRun": SPEC["originalRun"], "originalJob": SPEC["originalJob"],
            "attempts": 1, "separateSmoke": SMOKE, "primaryPrefix": EXPECTED,
            "originalPrimaryCap": 1200, "originalOutcomeBounds": {"shadow": 5, "preview": 8}}
    (output / "selection.json").write_text(json.dumps(plan, indent=2) + "\n")
    smoke_log, smoke_status, smoke_phase = run_phase("smoke", [SMOKE], 90, True, output)
    smoke_valid = (smoke_status == 0
        and [r["test"] for r in cases(smoke_log)] == [SMOKE]
        and cases(smoke_log)[0]["outcome"] == "passed"
        and "Native suite primary status=0; cleanup status=0" in smoke_log
        and "AppKit loop smoke: delayedHeartbeat=true, completed=true" in smoke_log)
    if not smoke_valid:
        (output / "result.json").write_text(json.dumps({"smokeValid": False, "smoke": smoke_phase}, indent=2) + "\n")
        return 1
    prefix_log, prefix_status, prefix_phase = run_phase("prefix", EXPECTED, 1200, False, output)
    report = analyze(prefix_log, prefix_status)
    report.update({"smokeValid": True, "smoke": smoke_phase, "prefix": prefix_phase})
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "actual"}, indent=2))
    return 0 if report["allPassed"] else 1

if __name__ == "__main__":
    sys.exit(main())
