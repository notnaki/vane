#!/usr/bin/env python3
"""One diagnostic attempt; preserve process boundaries and the recorded history."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


BASE = "81a355405d9216548baa42be06b66208d454ee8d"
TARGET = "VaneTests.KeyboardAccessibilityTests/testF6LeavesTheLocalEaselForBrowserControls"
SMOKE = "VaneTests.NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops"
RETIRE = "VaneTests.NativeFixtureRetirementTests/testRetireManifest"
EVENT = re.compile(r"Test Case '-\[(VaneTests[.]\w+) (\w+)\]' (started|passed|failed|skipped)")
SKIP_REASON = re.compile(r"-\[(VaneTests[.]\w+) (\w+)\].*Test skipped - (.*)$")
DRIVER = re.compile(r"NATIVE TEST DRIVER pid=(\d+) phase=(primary|cleanup)")


def observe(raw):
    phases = []
    for line in raw.splitlines():
        driver = DRIVER.search(line)
        if driver:
            phases.append({"driver_pid": int(driver[1]), "phase": driver[2], "events": [], "skip_reasons": [], "host_identities": []})
        if not phases:
            continue
        event = EVENT.search(line)
        if event:
            phases[-1]["events"].append({"test": event[1] + "/" + event[2], "event": event[3]})
        skip = SKIP_REASON.search(line)
        if skip:
            phases[-1]["skip_reasons"].append({"test": skip[1] + "/" + skip[2], "reason": skip[3]})
        if line.startswith("F6_PROCESS "):
            try:
                phases[-1]["host_identities"].append(json.loads(line.removeprefix("F6_PROCESS ")))
            except ValueError:
                phases[-1]["host_identities"].append({"invalid_json": line})
    status = re.findall(r"Native suite primary status=(-?\d+); cleanup status=(-?\d+)", raw)
    return {"phases": phases, "statuses": [{"primary": int(a), "cleanup": int(b)} for a, b in status],
            "fatal_signal": bool(re.search(r"^\*\*\* Signal \d+: Backtracing", raw, re.M))}


def classify(observation, expected, expected_skips, target=None, require_host_identity=True):
    reasons = []
    phases = observation["phases"]
    if [p["phase"] for p in phases] != ["primary", "cleanup"]:
        reasons.append("wrong or missing primary/cleanup phase boundaries")
    primary = phases[0] if phases and phases[0]["phase"] == "primary" else {"events": []}
    events = primary["events"]
    starts = [e["test"] for e in events if e["event"] == "started"]
    terminals = [e for e in events if e["event"] != "started"]
    if starts != expected:
        reasons.append("ordered starts differ from recorded primary")
    if [e["test"] for e in terminals] != expected:
        reasons.append("ordered completions differ from recorded primary")
    skips = [e["test"] for e in terminals if e["event"] == "skipped"]
    if skips != expected_skips:
        reasons.append("skip pattern differs from recorded primary")
    expected_reasons = [{"test": name, "reason": "Requires animated edge navigation"} for name in expected_skips]
    if primary.get("skip_reasons", []) != expected_reasons:
        reasons.append("skip reasons differ from recorded primary")
    failures = [e["test"] for e in terminals if e["event"] == "failed"]
    if failures and failures != ([target] if target else []):
        reasons.append("earlier or unexpected failure")
    if len(phases) == 2:
        if phases[1]["events"] != [{"test": RETIRE, "event": "started"}, {"test": RETIRE, "event": "passed"}]:
            reasons.append("fresh cleanup case did not complete exactly once")
    statuses = observation["statuses"]
    if len(statuses) != 1 or statuses[0]["cleanup"] != 0:
        reasons.append("cleanup status missing or unverified")
    elif statuses[0]["primary"] != (1 if failures else 0):
        reasons.append("primary status does not match native assertions")
    if observation["fatal_signal"]:
        reasons.append("fatal signal")
    if "driver_status" in observation and statuses and observation["driver_status"] != (1 if statuses[0]["primary"] or statuses[0]["cleanup"] else 0):
        reasons.append("wrapper exit status disagrees with native statuses")
    if require_host_identity:
        identities = []
        for phase in phases:
            hosts = phase.get("host_identities", [])
            if len(hosts) != 1 or not isinstance(hosts[0].get("pid"), int) or hosts[0]["pid"] <= 0 or not isinstance(hosts[0].get("start"), int) or hosts[0]["start"] <= 0 or not hosts[0].get("path", "").startswith("/") or hosts[0].get("retirement_phase") != phase["phase"]:
                reasons.append("actual host identity missing or invalid for " + phase["phase"])
            else:
                identities.append((hosts[0]["pid"], hosts[0]["start"]))
        if len(identities) == 2 and identities[0] == identities[1]:
            reasons.append("primary and fresh cleanup reused one native host")
    if reasons:
        return {"classification": "non-discriminating", "reasons": reasons}
    return {"classification": "matched-history-target-failure" if failures else
            ("matched-history-non-reproduction-not-repair-proof" if target else "preflight-admitted"), "reasons": []}


def main():
    directory = Path(os.environ["RUNNER_TEMP"])
    baseline = json.loads(Path("scripts/fixtures/pr635-f6-prefix-baseline.json").read_text())
    expected = baseline["primary_prefix"]["ordered_case_ids"]
    assert baseline["source_head"] == BASE
    assert len(expected) == 258 and len(set(expected)) == 258 and expected[-1] == TARGET
    assert SMOKE not in expected and RETIRE not in expected
    inventory = subprocess.run(["swift", "test", "list", "--skip-build"], text=True, capture_output=True, check=True)
    (directory / "pr635-prefix-inventory.txt").write_text(inventory.stdout + inventory.stderr)
    assert set(expected + [SMOKE, RETIRE]) <= set(inventory.stdout.splitlines())
    selector = baseline["primary_prefix"]["selector"]
    assert selector == "^(?:" + "|".join(map(re.escape, expected)) + ")$"
    manifest = {"head": os.environ["GITHUB_SHA"], "exact_base": BASE, "attempts": 1,
                "baseline": baseline, "initial_workspace_read_observer_effect":
                "Class setup reads NSWorkspace before the original first case; NSApp existence is logged before/after. No NSApplication is created by diagnostics.",
                "stages": []}
    manifest_path = directory / "pr635-prefix-manifest.json"

    def persist():
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    def run(stage, selected, timeout, smoke=False):
        environment = dict(os.environ, VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT=str(timeout))
        environment.pop("VANE_APPKIT_LOOP_SMOKE", None)
        if smoke:
            environment["VANE_APPKIT_LOOP_SMOKE"] = "1"
        log_path = directory / ("pr635-prefix-" + stage + "-raw.log")
        command = ["python3", "scripts/run-native-tests.py", "--skip-build", "--jobs", "1", "--filter", selected]
        record = {"name": stage, "command": command, "primary_timeout": timeout, "log": log_path.name}
        manifest["stages"].append(record)
        persist()
        with log_path.open("w") as log:
            process = subprocess.Popen(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            record["wrapper_pid"] = process.pid
            persist()
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
            record["driver_status"] = process.wait()
        record.update(observe(log_path.read_text()))
        persist()
        return record

    preflight = run("smoke", "^" + re.escape(SMOKE) + "$", 90, smoke=True)
    preflight.update(classify(preflight, [SMOKE], []))
    if "AppKit loop smoke: delayedHeartbeat=true, completed=true" not in (directory / preflight["log"]).read_text():
        preflight["classification"] = "non-discriminating"
        preflight["reasons"].append("delayed heartbeat smoke evidence missing")
    persist()
    if preflight["classification"] != "preflight-admitted" or preflight["driver_status"] != 0:
        manifest["classification"] = "non-discriminating-preflight"
        persist()
        return 1
    prefix = run("primary258", selector, 1200)
    prefix.update(classify(prefix, expected, baseline["primary_prefix"]["expected_skips"], TARGET))
    manifest["classification"] = prefix["classification"]
    persist()
    print(json.dumps({"head": manifest["head"], "classification": manifest["classification"],
                      "reasons": prefix["reasons"], "driver_status": prefix["driver_status"],
                      "statuses": prefix["statuses"]}, indent=2), flush=True)
    return 0 if prefix["classification"] == "matched-history-non-reproduction-not-repair-proof" and prefix["driver_status"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
