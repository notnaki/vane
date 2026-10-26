#!/usr/bin/env python3
"""Exercise shard coverage and completion against executable CLI boundaries."""

import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("native-test-shards.py")


class NativeTestShardsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.inventory = self.root / "inventory.txt"
        self.weights = self.root / "durations.json"
        self.weights.write_text(json.dumps({"classes": {
            "VaneTests.Slow": 10, "VaneTests.Medium": 6, "VaneTests.Fast": 4}}))

    def plan(self, tests, index=1, count=2, success=True):
        self.inventory.write_text("\n".join(tests) + "\n")
        manifest = self.root / f"shard-{index}.json"
        pattern = self.root / f"shard-{index}.filter"
        result = subprocess.run([
            sys.executable, str(SCRIPT), "plan", "--inventory", str(self.inventory),
            "--index", str(index), "--count", str(count), "--durations", str(self.weights),
            "--manifest", str(manifest), "--filter-output", str(pattern),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if success:
            return json.loads(manifest.read_text()), pattern.read_text().strip()
        self.assertFalse(manifest.exists())

    def test_balances_duration_without_splitting_classes_or_losing_new_tests(self):
        tests = ["VaneTests.Slow/testA", "VaneTests.Slow/testB", "VaneTests.Medium/testA",
                 "VaneTests.Fast/testA", "VaneTests.New/testAdded"]
        first, first_filter = self.plan(tests)
        second, second_filter = self.plan(list(reversed(tests)), index=2)
        self.assertEqual(first["tests"], ["VaneTests.New/testAdded", "VaneTests.Slow/testA", "VaneTests.Slow/testB"])
        self.assertEqual(second["tests"], ["VaneTests.Fast/testA", "VaneTests.Medium/testA"])
        self.assertEqual(first["inventory_sha256"], second["inventory_sha256"])
        self.assertEqual(set(first["tests"]) | set(second["tests"]), set(tests))
        self.assertFalse(set(first["tests"]) & set(second["tests"]))
        for manifest, pattern in ((first, first_filter), (second, second_filter)):
            self.assertEqual([test for test in sorted(tests) if re.search(pattern, test)], manifest["tests"])
            self.assertIsNone(re.search(pattern, "OtherVaneTests.Slow/testA"))
            self.assertIsNone(re.search(pattern, "VaneTests.SlowExtra/testA"))
        repeated, repeated_filter = self.plan(list(reversed(tests)))
        self.assertEqual(repeated, first)
        self.assertEqual(repeated_filter, first_filter)

    def test_zero_duration_classes_still_distribute_across_all_shards(self):
        self.weights.write_text(json.dumps({"classes": {f"VaneTests.C{i}": 0 for i in range(8)}}))
        tests = [f"VaneTests.C{i}/testA" for i in range(8)]
        groups = [self.plan(tests, index=i, count=4)[0]["tests"] for i in range(1, 5)]
        self.assertEqual([len(group) for group in groups], [2, 2, 2, 2])
        self.assertEqual(sorted(test for group in groups for test in group), tests)

    def test_rejects_invalid_discovery_and_shard_parameters(self):
        for tests, index, count in [([], 1, 2), (["warning: no tests"], 1, 2),
                                    (["VaneTests.A/test", "VaneTests.A/test"], 1, 1),
                                    (["VaneTests.A/test"], 0, 1), (["VaneTests.A/test"], 2, 1),
                                    (["VaneTests.A/test"], 1, 0), (["VaneTests.A/test"], 1, 2)]:
            with self.subTest(tests=tests, index=index, count=count):
                self.plan(tests, index, count, success=False)

    def test_rejects_invalid_duration_weights(self):
        for weight in (-1, "slow", float("nan"), float("inf"), True):
            with self.subTest(weight=weight):
                self.weights.write_text(json.dumps({"classes": {"VaneTests.A": weight}}))
                self.plan(["VaneTests.A/test"], count=1, success=False)

    def verify(self, text, success):
        log = self.root / "tests.log"
        log.write_text(text)
        result = subprocess.run([sys.executable, str(SCRIPT), "verify", "--manifest",
                                 str(self.root / "shard-1.json"), "--log", str(log)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def test_requires_every_selected_test_to_finish_and_cleanup_to_succeed(self):
        self.plan(["VaneTests.A/testOne", "VaneTests.A/testTwo"], count=1)
        first = "Test Case '-[VaneTests.A testOne]' passed (0.001 seconds).\n"
        second = "Test Case '-[VaneTests.A testTwo]' skipped (0.001 seconds).\n"
        cleanup = "Native suite primary status=0; cleanup status=0\n"
        self.verify(first + second + cleanup, True)
        self.verify(first + cleanup, False)
        self.verify(first + second, False)
        self.verify(first + second + cleanup.replace("cleanup status=0", "cleanup status=1"), False)
        self.verify(first + second.replace("skipped", "failed") + cleanup, False)
        self.verify(first + second + "*** Signal 5: Backtracing\n" + cleanup, False)
        self.verify("Test Case '-[Other.A testOne]' passed (0.001 seconds).\n" + second + cleanup, False)

    def test_empty_or_duplicate_manifest_cannot_pass_on_cleanup_alone(self):
        for tests in ([], ["VaneTests.A/test", "VaneTests.A/test"]):
            (self.root / "shard-1.json").write_text(json.dumps({"schema": 1, "tests": tests}))
            self.verify("Native suite primary status=0; cleanup status=0\n", False)


if __name__ == "__main__":
    unittest.main()
