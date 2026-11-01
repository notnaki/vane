#!/usr/bin/env python3
"""Historical replay only; current worker identity failures block native CI.

Allow only the named bare-engine worker-UA discrepancy; fail everything else."""
import argparse
import json
import math
from pathlib import Path
import re

TEST_CLASS = "VaneTests.ExtensionUserAgentTests"
TEST_METHOD = "testKnownServiceWorkerUserAgentLimitation"
PROBE = TEST_CLASS + "/" + TEST_METHOD
RETIREMENT = "VaneTests.NativeFixtureRetirementTests/testRetireManifest"
COMPLETED = re.compile(r"^Test Case '-\[([^ ]+) ([^ ]+)\]' (passed|failed|skipped) \([0-9.]+ seconds\)\.$", re.MULTILINE)
STARTED = re.compile(r"^Test Case '-\[([^ ]+) ([^ ]+)\]' started\.$", re.MULTILINE)
ASSERTION = re.compile(
    r'^.+/ExtensionUserAgentTests\.swift:[0-9]+: error: -\[' + re.escape(TEST_CLASS + " " + TEST_METHOD)
    + r'\] : XCTAssertEqual failed: \("Optional\("([^"\r\n]+)"\)"\) is not equal to '
    + r'\("Optional\("([^"\r\n]+)"\)"\) - Known WebKit worker UA limitation: '
    + r'(default Safari worker|custom worker|Safari worker after custom worker) (startup|current)$')
ENGINE = re.compile(r"Mozilla/5\.0 \(Macintosh; Intel Mac OS X [0-9]+(?:_[0-9]+)*\) AppleWebKit/([0-9]+(?:\.[0-9]+)*) \(KHTML, like Gecko\)")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def classify(manifest, pattern, log, runner_status, tee_status):
    require(tee_status == 0, "probe log capture failed")
    require(all(type(manifest.get(key)) is int for key in ("schema", "index", "count"))
            and manifest.get("schema") == 1 and manifest.get("suite") == "known-limitations"
            and manifest.get("index") == 1 and manifest.get("count") == 1
            and manifest.get("tests") == [PROBE], "manifest must select exactly the named worker-UA probe")
    require(re.fullmatch(r"[0-9a-f]{64}", manifest.get("inventory_sha256", "")), "invalid inventory fingerprint")
    shards = manifest.get("shards")
    require(isinstance(shards, list) and len(shards) == 1 and isinstance(shards[0], dict)
            and all(type(shards[0].get(key)) is int for key in ("index", "tests")) and shards[0].get("index") == 1
            and shards[0].get("tests") == 1, "invalid single-probe shard manifest")
    duration = shards[0].get("estimated_seconds")
    require(type(duration) in (int, float) and math.isfinite(duration) and duration >= 0, "invalid duration estimate")
    require(pattern.strip() == "^(?:" + re.escape(PROBE) + ")$", "filter does not select exactly the manifest probe")
    require(log.strip(), "empty probe log")
    require(not re.search(r"\*\*\* Signal|NATIVE PRIMARY TIMEOUT|UNVERIFIED|Fatal error:|unexpected signal|process crashed", log, re.IGNORECASE),
            "crash, timeout, or unverified retirement in probe")
    summaries = re.findall(r"^Native suite primary status=([0-9]+); cleanup status=([0-9]+)$", log, re.MULTILINE)
    require(len(summaries) == 1 and log.splitlines()[-1].startswith("Native suite primary status="),
            "missing, duplicate, or incomplete wrapper result")
    primary_status, cleanup_status = map(int, summaries[0])
    require(primary_status in (0, 1) and cleanup_status == 0 and runner_status == primary_status,
            "runner, primary, and verified cleanup statuses disagree")
    drivers = list(re.finditer(r"^NATIVE TEST DRIVER pid=[1-9][0-9]* phase=(primary|cleanup)$", log, re.MULTILINE))
    require([match[1] for match in drivers] == ["primary", "cleanup"], "expected one primary and one fresh cleanup driver")
    primary, cleanup = log[:drivers[1].start()], log[drivers[1].start():]
    for phase, expected in ((primary, PROBE), (cleanup, RETIREMENT)):
        require([f"{match[1]}/{match[2]}" for match in STARTED.finditer(phase)] == [expected],
                "missing, duplicate, or unexpected test start")
        require("Native test host bootstrap: beforeAppKit=true, configured=true" in phase.splitlines(),
                "native host bootstrap not verified")
    primary_completed = [(f"{match[1]}/{match[2]}", match[3]) for match in COMPLETED.finditer(primary)]
    cleanup_completed = [(f"{match[1]}/{match[2]}", match[3]) for match in COMPLETED.finditer(cleanup)]
    require(primary_completed == [(PROBE, "passed" if primary_status == 0 else "failed")], "probe did not complete exactly once without skipping")
    require(cleanup_completed == [(RETIREMENT, "passed")], "fresh cleanup test did not complete successfully")
    require(re.search(r"^Vane fixture diagnostic: retirement complete: [0-9]+ exact owned backends absent$", cleanup, re.MULTILINE),
            "owned backend retirement not verified")
    require(not re.search(r"\berror:", cleanup, re.IGNORECASE), "cleanup reported an assertion or other error")
    failures = []
    for line in primary.splitlines():
        if not re.search(r"\berror:", line, re.IGNORECASE):
            continue
        match = ASSERTION.fullmatch(line)
        require(match is not None, "unrecognized assertion or error in named probe")
        actual, expected, stage, field = match.groups()
        engine = ENGINE.fullmatch(actual)
        require(engine is not None, "worker mismatch is not the known nonnil bare-engine UA")
        if stage == "custom worker":
            require(expected == "Vane Prior Worker Identity/1.0 (no Safari token)", "unexpected custom worker identity")
        else:
            require(re.fullmatch(re.escape(actual) + r" Version/[0-9]+(?:\.[0-9]+)* Safari/" + re.escape(engine[1]), expected),
                    "unexpected Safari worker identity")
        pair = (stage, field)
        require(pair not in failures, "duplicate worker comparison failure")
        failures.append(pair)
    require(bool(failures) == (primary_status == 1), "assertion failures disagree with primary result")
    for phase, count, outcome in ((primary, len(failures), "failed" if primary_status else "passed"), (cleanup, 0, "passed")):
        suites = re.findall(r"^Test Suite '.+' (passed|failed) at .+$", phase, re.MULTILINE)
        require(suites and all(result == outcome for result in suites), "XCTest suite outcomes disagree with primary or cleanup")
        totals = re.findall(r"^\s*Executed ([0-9]+) tests?, with ([0-9]+) failures? \(([0-9]+) unexpected\) in .+$", phase, re.MULTILINE)
        require(totals and all(tuple(map(int, total)) == (1, count, 0) for total in totals),
                "XCTest completion totals disagree or contain unexpected failures")
    return "known-limitation" if failures else "passed-sample", failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "filter", "log"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--runner-status", type=int, required=True)
    parser.add_argument("--tee-status", type=int, required=True)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    try:
        result, failures = classify(json.loads(args.manifest.read_text()), args.filter.read_text(),
                                    args.log.read_text(), args.runner_status, args.tee_status)
        message = f"Extension worker UA: **{result}** ({len(failures)} known comparisons). "
        message += "A passing sample does not establish a repair; platform-limitation evidence is retained in issue #513.\n"
        if args.summary:
            with args.summary.open("a") as summary: summary.write(message)
        print(message.strip())
    except (ValueError, OSError, TypeError, KeyError, AttributeError) as error:
        message = "Worker UA validation failed: " + str(error)
        if args.summary:
            with args.summary.open("a") as summary: summary.write(message + "\n")
        parser.exit(1, message + "\n")


if __name__ == "__main__": main()
