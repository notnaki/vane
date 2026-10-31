#!/usr/bin/env python3
"""Partition discovered XCTest classes across isolated runners; verify execution."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


IDENTIFIER = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/[^\s/]+")
COMPLETED = re.compile(r"Test Case '-\[([^ ]+) ([^ ]+)\]' (passed|skipped|failed) \(")
BOOTSTRAP_DIAGNOSTIC = "Native test host bootstrap: beforeAppKit=true, configured=true"
# Worker navigator identity is required coverage. A missing/renamed regression
# fails planning instead of silently deleting the former advisory's assertions.
REQUIRED_WORKER_IDENTITY = {"VaneTests.ExtensionUserAgentTests/testServiceWorkerNavigatorIdentityAcrossSelections"}


def validate_tests(tests):
    if not isinstance(tests, list) or not tests:
        raise ValueError("test inventory must be nonempty")
    if any(not isinstance(test, str) or not IDENTIFIER.fullmatch(test) for test in tests):
        raise ValueError("malformed test identifier in inventory")
    if len(set(tests)) != len(tests):
        raise ValueError("duplicate test identifier in inventory")


def plan(arguments):
    # SwiftPM merges the test bundle's stderr into list output. The test-only
    # constructor emits this success diagnostic even when no tests execute.
    tests = [line.strip() for line in arguments.inventory.read_text().splitlines()
             if line.strip() and line.strip() != BOOTSTRAP_DIAGNOSTIC]
    validate_tests(tests)
    inventory = tests
    if arguments.suite == "required":
        missing = REQUIRED_WORKER_IDENTITY - set(tests)
        if missing:
            raise ValueError("required worker identity probe missing from inventory: " + ", ".join(sorted(missing)))
    if not 1 <= arguments.index <= arguments.count:
        raise ValueError("shard index must be between 1 and count")
    classes = {}
    for test in sorted(tests):
        classes.setdefault(test.split("/", 1)[0], []).append(test)
    if len(classes) < arguments.count:
        raise ValueError("not enough test classes for nonempty shards")
    weights = json.loads(arguments.durations.read_text())["classes"]
    if not isinstance(weights, dict) or any(
        isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0
        for value in weights.values()
    ):
        raise ValueError("duration weights must be finite nonnegative numbers")

    # Longest classes go first. Discovery alone defines coverage; weights are hints.
    estimates = {name: max(0.1, weights.get(name, 0.25 * len(methods)))
                 for name, methods in classes.items()}
    shards = [{"tests": [], "classes": [], "estimated_seconds": 0.0} for _ in range(arguments.count)]
    for name in sorted(classes, key=lambda name: (-estimates[name], name)):
        target = min(range(arguments.count), key=lambda index: (shards[index]["estimated_seconds"], index))
        shards[target]["classes"].append(name)
        shards[target]["tests"].extend(classes[name])
        shards[target]["estimated_seconds"] += estimates[name]

    assigned = [test for shard in shards for test in shard["tests"]]
    if sorted(assigned) != sorted(tests) or any(not shard["tests"] for shard in shards):
        raise ValueError("shards must cover the inventory exactly once and be nonempty")
    selected = shards[arguments.index - 1]
    pattern = "^(?:" + "|".join(re.escape(name) for name in sorted(selected["classes"])) + ")/"
    if sorted(test for test in inventory if re.search(pattern, test)) != sorted(selected["tests"]):
        raise ValueError("filter does not match the selected tests exactly")
    manifest = {
        "schema": 1, "index": arguments.index, "count": arguments.count,
        "inventory_sha256": hashlib.sha256("\n".join(sorted(inventory)).encode()).hexdigest(),
        "suite": arguments.suite,
        "tests": sorted(selected["tests"]),
        "shards": [{"index": index + 1, "tests": len(shard["tests"]),
                    "estimated_seconds": round(shard["estimated_seconds"], 3)}
                   for index, shard in enumerate(shards)],
    }
    arguments.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    arguments.filter_output.write_text(pattern + "\n")
    print(f"Inventory: {len(tests)} tests, {len(classes)} classes, sha256={manifest['inventory_sha256']}")
    for shard in manifest["shards"]:
        print(f"Shard {shard['index']}/{arguments.count}: {shard['tests']} tests; "
              f"estimated {shard['estimated_seconds']:.1f}s (advisory)")


def verify(arguments):
    manifest = json.loads(arguments.manifest.read_text())
    if manifest["schema"] != 1:
        raise ValueError("unsupported shard manifest schema")
    tests = manifest["tests"]
    validate_tests(tests)
    log = arguments.log.read_text()
    if re.search(r"^\*\*\* Signal [0-9]+: Backtracing", log, re.MULTILINE):
        raise ValueError("fatal Swift signal in native shard")
    if "Native suite primary status=0; cleanup status=0" not in log.splitlines():
        raise ValueError("native primary and cleanup did not both succeed")
    finished = set()
    for match in COMPLETED.finditer(log):
        if match[3] == "failed":
            raise ValueError(f"native test failed: {match[1]}/{match[2]}")
        finished.add(f"{match[1]}/{match[2]}")
    missing = sorted(set(tests) - finished)
    if missing:
        raise ValueError(f"{len(missing)} selected tests did not finish: " + ", ".join(missing[:10]))
    print(f"PASS: all {len(tests)} selected tests completed; primary and cleanup succeeded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planner = commands.add_parser("plan")
    planner.add_argument("--inventory", type=Path, required=True)
    planner.add_argument("--index", type=int, required=True)
    planner.add_argument("--count", type=int, required=True)
    planner.add_argument("--durations", type=Path, default=Path(__file__).with_name("native-test-durations.json"))
    planner.add_argument("--manifest", type=Path, required=True)
    planner.add_argument("--filter-output", type=Path, required=True)
    planner.add_argument("--suite", choices=("all", "required"), default="all")
    checker = commands.add_parser("verify")
    checker.add_argument("--manifest", type=Path, required=True)
    checker.add_argument("--log", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        (plan if arguments.command == "plan" else verify)(arguments)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"native shard error: {error}\n")


if __name__ == "__main__":
    main()
