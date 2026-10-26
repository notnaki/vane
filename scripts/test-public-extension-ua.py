#!/usr/bin/env python3
"""Pure protocol and fake-process guards. Never compile/sign/launch native code."""
import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("public_probe", Path(__file__).with_name("check-public-extension-ua.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def fixture(mismatch=None, cleanup=True):
    ua = "Mozilla/5.0 AppleWebKit/605.1.15 " + probe.SUFFIX
    records = [{"event": "launch", "arm": probe.ARM, "finishedLaunching": True, "appRunning": True,
                "WebKit": "21624.5.1.11.3", "OS": "Version26.6.2 (25G83)", "ownedDataStoreID": str(uuid.uuid4())}]
    for index, label in enumerate(probe.STAGES):
        nonce = str(uuid.uuid4())
        worker = {"startup": ua, "current": ua, "nonce": nonce, "runtime": nonce, "host": nonce,
                  "scheme": "webkit-extension:", "version": "2" if index == 0 else "3"}
        if index == mismatch: worker.update(startup="Bare WebKit", current="Bare WebKit")
        records.append({"event": "observation", "arm": probe.ARM, "stage": label,
            "boundToCurrentContext": True, "popupPoolStoreAndControllerMatch": True,
            "startupAndCurrentMatch": index != mismatch, "identity": {
                "startup": ua, "current": ua, "nonce": nonce, "runtime": nonce, "host": nonce, "worker": worker}})
        if index == mismatch:
            records.append({"event": "failure", "reason": "Worker/popup startup or current identity mismatch", "stage": index})
            break
    records.append({"event": "summary", "completedStages": 4 if mismatch is None else mismatch,
        "mismatchOrHarnessFailure": mismatch is not None, "ownedStoreRemovalCallbackSucceeded": cleanup,
        "backendRetirementVerified": False})
    return records


def encoded(records):
    return ("\n".join(json.dumps(record) for record in records) + "\n").encode()


class ProtocolTests(unittest.TestCase):
    def test_complete_finite_sample_and_valid_bound_mismatch_are_distinct(self):
        result = probe.validate_probe_output(encoded(fixture()), 0)
        self.assertEqual(result["result"], "PUBLIC_ARM_SAMPLE_PASSED")
        self.assertEqual(result["completedStages"], 4)
        for index in range(4):
            with self.subTest(index=index):
                result = probe.validate_probe_output(encoded(fixture(mismatch=index)), 1)
                self.assertEqual(result["result"], "PUBLIC_UA_MISMATCH_OBSERVED")
                self.assertEqual(result["completedStages"], index)
                self.assertFalse(result["backendRetirementVerified"])

    def test_missing_duplicate_reordered_unknown_and_malformed_records_never_pass(self):
        full = fixture()
        samples = [[], full[:-1], full[:1] + full[2:], full[:2] + [full[1]] + full[2:],
                   full[:1] + [full[2], full[1]] + full[3:], full + [{"event": "other"}]]
        for records in samples:
            with self.subTest(records=records), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)
        with self.assertRaises(ValueError): probe.validate_probe_output(b"{not JSON}\n", 0)

    def test_launch_context_nonce_runtime_origin_manifest_and_ownership_guards_remain_strict(self):
        mutations = [(0, "finishedLaunching", False), (0, "appRunning", False), (0, "arm", "Vane-SPI"),
                     (0, "WebKit", "unknown"), (0, "ownedDataStoreID", "bad"),
                     (1, "boundToCurrentContext", False), (1, "popupPoolStoreAndControllerMatch", False)]
        for index, key, value in mutations:
            records = fixture(); records[index][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)
        for key, value in [("nonce", str(uuid.uuid4())), ("runtime", "old"), ("host", "other"),
                           ("scheme", "https:"), ("version", "3")]:
            records = fixture(); records[1]["identity"]["worker"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)

    def test_exit_store_cleanup_stage_count_and_backend_claim_cannot_be_softened(self):
        for status, records in [(5, fixture()), (0, fixture(cleanup=False)), (0, fixture(mismatch=1))]:
            with self.subTest(status=status), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), status)
        for key, value in [("completedStages", 0), ("backendRetirementVerified", True), ("mismatchOrHarnessFailure", True)]:
            records = fixture(); records[-1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)
        # A real bound UA mismatch may still be observed if its separate store cleanup failed;
        # the result stays failed and explicitly reports cleanup=false.
        result = probe.validate_probe_output(encoded(fixture(mismatch=1, cleanup=False)), 1)
        self.assertEqual(result["result"], "PUBLIC_UA_MISMATCH_OBSERVED")
        self.assertFalse(result["ownedStoreRemovalCallbackSucceeded"])

    def test_startup_and_later_values_and_native_result_must_agree(self):
        for payload, key, value in [("worker", "startup", "Bare WebKit"), ("worker", "current", "Bare WebKit"),
                                    ("popup", "startup", "Bare WebKit"), ("popup", "current", "Bare WebKit")]:
            records = fixture()
            target = records[1]["identity"]["worker"] if payload == "worker" else records[1]["identity"]
            target[key] = value
            with self.subTest(payload=payload, key=key), self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)


class AdapterTests(unittest.TestCase):
    def fake_run(self, mismatch=None, exited=True):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        bundle = root / "Probe.app"; executable = bundle / "Contents/MacOS/WorkerUAProbe"
        executable.parent.mkdir(parents=True); executable.write_bytes(b"not an executable")
        evidence = root / "logs"
        calls = []
        def fake_process(command, environment, timeout, log, interrupted):
            self.assertEqual(command, [str(executable)])
            self.assertEqual(timeout, 90)
            self.assertNotIn("VANE_DATA_DIR", environment)
            output = b"x" * 70_000 + b"\n" + encoded(fixture(mismatch=mismatch))
            log.write_bytes(output); calls.append((log, output))
            return (1 if mismatch is not None else 0), exited, output
        with patch.object(probe.owned, "run_ua_process", side_effect=fake_process), redirect_stdout(io.StringIO()):
            status = probe.run_public_mode(bundle, evidence)
        return status, evidence, calls

    def test_fixed_eight_fresh_launches_keep_complete_capped_logs_and_distinct_evidence(self):
        status, evidence, calls = self.fake_run()
        self.assertEqual(status, 0); self.assertEqual(len(calls), 8)
        self.assertEqual({p.name for p in evidence.iterdir()}, {f"trial-{n:02d}" for n in range(1, 9)})
        for log, output in calls:
            self.assertEqual(log.read_bytes(), output); self.assertGreater(len(output), 65_536)
            result = json.loads(log.with_name("result.json").read_text())
            self.assertEqual(result["result"], "PUBLIC_ARM_SAMPLE_PASSED")
            self.assertFalse(result["backendRetirementVerified"])

    def test_first_mismatch_is_not_retried_and_unverified_exit_is_not_a_pass(self):
        for mismatch, exited in [(1, True), (None, False)]:
            with self.subTest(mismatch=mismatch, exited=exited):
                status, evidence, calls = self.fake_run(mismatch, exited)
                self.assertNotEqual(status, 0); self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0].read_bytes(), calls[0][1])
                result = json.loads(calls[0][0].with_name("result.json").read_text())
                self.assertNotEqual(result["result"], "PUBLIC_ARM_SAMPLE_PASSED")

    def test_workflow_binds_original_input_manifest_and_archives_logs_without_app_or_profile(self):
        source = (Path(__file__).resolve().parent.parent / ".github/workflows/public-extension-ua.yml").read_text()
        self.assertIn("c5cf33ec39cce0125b18f04bde01107c7876be3528586a6e0e09f37772c392e2", source)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", source)
        self.assertIn("if: ${{ always() }}", source)
        self.assertIn("${{ runner.temp }}/public-probe-logs/", source)
        self.assertIn("${{ runner.temp }}/public-probe-run.log", source)
        upload = source.split("- name: Preserve complete capped logs and scoped public evidence", 1)[1]
        self.assertNotIn("Probe.app", upload); self.assertNotIn("DataStore", upload)


if __name__ == "__main__": unittest.main()
