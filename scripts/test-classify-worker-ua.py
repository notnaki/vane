#!/usr/bin/env python3
"""Run the strict advisory classifier against preserved CI evidence and mutations."""
import json
import importlib.util
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
FIXTURE = ROOT / "fixtures/worker-ua/run40758318040"
PROBE = "VaneTests.ExtensionUserAgentTests testKnownServiceWorkerUserAgentLimitation"


class ClassifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.text = FIXTURE.with_suffix(".txt").read_text()
        self.manifest = json.loads(FIXTURE.with_suffix(".json").read_text())
        self.filter = FIXTURE.with_suffix(".filter").read_text()

    def classify(self, *, text=None, runner=1, tee=0, omit=None, success=False):
        files = {"log": self.text if text is None else text,
                 "manifest": json.dumps(self.manifest), "filter": self.filter}
        command = [sys.executable, str(ROOT / "classify-worker-ua.py"),
                   "--runner-status", str(runner), "--tee-status", str(tee),
                   "--summary", str(self.directory / "summary.md")]
        for name, content in files.items():
            path = self.directory / name
            path.unlink(missing_ok=True)
            if omit != name:
                path.write_text(content)
            command += ["--" + name, str(path)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_original_ci_failure_is_only_the_named_limitation(self):
        result = self.classify(success=True)
        self.assertIn("known-limitation", result.stdout)
        self.assertIn("4", result.stdout)
        self.assertIn("does not establish", (self.directory / "summary.md").read_text())

    def test_clean_passing_sample_is_not_reported_as_a_fix(self):
        text = "\n".join(line for line in self.text.splitlines() if ": error:" not in line) + "\n"
        text = text.replace(f"{PROBE}]' failed", f"{PROBE}]' passed")
        text = text.replace("' failed at", "' passed at")
        text = text.replace("4 failures", "0 failures").replace("primary status=1", "primary status=0")
        result = self.classify(text=text, runner=0, success=True)
        self.assertIn("passed-sample", result.stdout)
        self.assertIn("does not establish", (self.directory / "summary.md").read_text())

    def test_unknown_or_malformed_assertions_are_required_failures(self):
        error = next(line for line in self.text.splitlines() if ": error:" in line)
        for changed in (
            error.replace("Known WebKit worker UA limitation:", "Popup startup:"),
            error.replace('Optional("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)")', "nil", 1),
            error.replace('Optional("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)")', 'Optional("Wrong Identity/1.0")', 1),
            error.replace("default Safari worker startup", "unknown worker startup"),
            error.replace("Safari/605.1.15", "Safari/999.0"),
            error.replace("testKnownServiceWorkerUserAgentLimitation", "testOtherFailure"),
        ):
            with self.subTest(changed=changed):
                self.classify(text=self.text.replace(error, changed))
        self.classify(text=self.text.replace(error, error + "\n/fixture.swift:1: error: unexpected ownership failure"))
        self.classify(text=self.text.replace(error, error + "\nerror: unrecognized runner failure"))

    def test_all_six_known_comparisons_and_only_those_are_allowed(self):
        lines = self.text.splitlines()
        first = next(line for line in lines if ": error:" in line)
        errors = []
        safari = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15'
        for stage in ("default Safari worker", "custom worker", "Safari worker after custom worker"):
            for field in ("startup", "current"):
                error = first.replace("default Safari worker startup", stage + " " + field)
                if stage == "custom worker":
                    error = error.replace(safari, "Vane Prior Worker Identity/1.0 (no Safari token)")
                errors.append(error)
        text = self.text.replace(first, "\n".join(errors))
        text = "\n".join(line for line in text.splitlines() if ": error:" not in line or line in errors) + "\n"
        # The other three original failures are already among the six replacements.
        seen = set()
        unique = []
        for line in text.splitlines():
            if ": error:" in line:
                if line in seen: continue
                seen.add(line)
            unique.append(line)
        text = "\n".join(unique).replace("4 failures", "6 failures") + "\n"
        self.classify(text=text, success=True)
        self.classify(text=text.replace(errors[0], errors[0] + "\n" + errors[0]))

    def test_cleanup_crash_timeout_skip_and_incomplete_execution_fail(self):
        for text in (
            self.text.replace("cleanup status=0", "cleanup status=1"),
            self.text.replace("retirement complete: 1 exact owned backends absent", "UNVERIFIED native fixture retirement"),
            self.text.replace("NATIVE TEST DRIVER pid=1653", "*** Signal 5: Backtracing\nNATIVE TEST DRIVER pid=1653"),
            self.text.replace("NATIVE TEST DRIVER pid=1653", "NATIVE PRIMARY TIMEOUT seconds=180\nNATIVE TEST DRIVER pid=1653"),
            self.text.replace(f"{PROBE}]' failed", f"{PROBE}]' skipped"),
            self.text.replace(f"Test Case '-[{PROBE}]' failed (6.414 seconds).\n", ""),
            self.text.replace("testRetireManifest]' passed", "testRetireManifest]' failed"),
            self.text.replace("with 4 failures (0 unexpected)", "with 4 failures (1 unexpected)"),
            self.text.replace("with 4 failures", "with 5 failures"),
            self.text.replace("'ExtensionUserAgentTests' failed at", "'ExtensionUserAgentTests' passed at"),
            self.text.replace("Native suite primary status=1; cleanup status=0\n", ""),
        ):
            with self.subTest(text=text): self.classify(text=text)
        for runner, tee in ((0, 0), (124, 0), (1, 1), (1, 141)):
            with self.subTest(runner=runner, tee=tee): self.classify(runner=runner, tee=tee)

    def test_manifest_filter_and_evidence_must_match_exact_probe(self):
        for missing in ("log", "manifest", "filter"):
            with self.subTest(missing=missing): self.classify(omit=missing)
        for name, value in (("suite", "required"), ("tests", []), ("tests", ["VaneTests.Other/testA"]),
                            ("count", 2), ("schema", 2), ("schema", True), ("inventory_sha256", "bad")):
            original = self.manifest[name]
            self.manifest[name] = value
            with self.subTest(name=name): self.classify()
            self.manifest[name] = original
        self.filter = ".*"
        self.classify()

    def test_workflow_preserves_runner_and_capture_statuses(self):
        spec = importlib.util.spec_from_file_location("workflow_fixture", ROOT / "test-checks-workflow.py")
        workflow = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(workflow)
        section = workflow.jobs((ROOT.parent / ".github/workflows/checks.yml").read_text())["known-limitations"]
        script = workflow.block(section.split("- name: Exercise known WebKit worker UA behavior", 1)[1])
        commands = self.directory / "commands"
        commands.mkdir()
        for name, body in {
            "python3": '''if [ "$1" = scripts/run-native-tests.py ]; then
  cat "$CLASSIFIER_SAMPLE_LOG"
  exit "$CLASSIFIER_RUNNER_STATUS"
fi
exec "$CLASSIFIER_REAL_PYTHON" "$@"
''',
            "tee": '/usr/bin/tee "$@"\nexit "$CLASSIFIER_TEE_STATUS"\n',
        }.items():
            path = commands / name
            path.write_text("#!/bin/bash\nset -eu\n" + body)
            path.chmod(0o755)
        for suffix, value in (("log", self.text), ("json", json.dumps(self.manifest)), ("filter", self.filter)):
            (self.directory / ("vane-known-limitations." + suffix)).write_text(value)
        for runner, tee, wanted in ((1, 0, True), (124, 0, False), (1, 1, False), (0, 0, False)):
            env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(self.directory), "GITHUB_STEP_SUMMARY": str(self.directory / "summary.md"),
                   "CLASSIFIER_SAMPLE_LOG": str(FIXTURE.with_suffix(".txt")),
                   "CLASSIFIER_REAL_PYTHON": sys.executable,
                   "CLASSIFIER_RUNNER_STATUS": str(runner), "CLASSIFIER_TEE_STATUS": str(tee)}
            result = subprocess.run(["bash", "-c", script], cwd=ROOT.parent, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, wanted, result.stdout + result.stderr)

    def test_workflow_archives_every_exact_nonempty_evidence_file(self):
        spec = importlib.util.spec_from_file_location("workflow_fixture", ROOT / "test-checks-workflow.py")
        workflow = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(workflow)
        section = workflow.jobs((ROOT.parent / ".github/workflows/checks.yml").read_text())["known-limitations"]
        name = "- name: Prepare known limitation evidence archive"
        self.assertIn(name, section)
        prepare = section.split(name, 1)[1].split("- name: Preserve known limitation evidence", 1)[0]
        self.assertIn("if: ${{ always() }}", prepare)
        script = workflow.block(prepare)
        upload = section.split("- name: Preserve known limitation evidence", 1)[1]
        destination = re.search(r"^          path: \$\{\{ runner.temp \}\}/([^\n]+)$", upload, re.MULTILINE)
        self.assertIsNotNone(destination, "Upload exactly one prepared archive")
        expected = {"vane-known-limitations.log": FIXTURE.with_suffix(".txt").read_bytes(),
                    "vane-known-limitations.json": FIXTURE.with_suffix(".json").read_bytes(),
                    "vane-known-limitations.filter": FIXTURE.with_suffix(".filter").read_bytes()}
        for bad, empty in [(None, False), *[(name, empty) for name in expected for empty in (False, True)]]:
            with self.subTest(file=bad, empty=empty), tempfile.TemporaryDirectory(dir=self.directory) as directory:
                root = Path(directory)
                if bad is not None: (root / destination[1]).write_bytes(b"stale evidence must not survive")
                for name, content in expected.items():
                    if name != bad or empty:
                        (root / name).write_bytes(b"" if name == bad else content)
                result = subprocess.run(["bash", "-c", script], env={**os.environ, "RUNNER_TEMP": directory},
                                        capture_output=True, text=True)
                archive = root / destination[1]
                self.assertEqual(result.returncode == 0, bad is None, result.stderr)
                if bad is not None:
                    self.assertFalse(archive.exists(), "Never publish a partial evidence archive")
                else:
                    with tarfile.open(archive) as bundle:
                        self.assertEqual(sorted(bundle.getnames()), sorted(expected))
                        for name, content in expected.items(): self.assertEqual(bundle.extractfile(name).read(), content)
        with tempfile.TemporaryDirectory(dir=self.directory) as directory:
            root = Path(directory)
            for name, content in expected.items(): (root / name).write_bytes(content)
            command = root / "tar"
            command.write_text('#!/bin/bash\nprintf partial > "$2"\nexit 2\n')
            command.chmod(0o755)
            result = subprocess.run(["bash", "-c", script], env={**os.environ, "RUNNER_TEMP": directory,
                                    "PATH": directory + os.pathsep + os.environ["PATH"]}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / destination[1]).exists())
            self.assertFalse(list(root.glob("vane-known-limitations-evidence.*")), "Remove unpublished partial archives")


if __name__ == "__main__": unittest.main()
