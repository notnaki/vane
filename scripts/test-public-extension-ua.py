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


class FreshMV3ControlTests(unittest.TestCase):
    def records(self, mismatch=False):
        records = fixture(mismatch=1 if mismatch else None)
        records = [records[0], records[2]] + records[-2:] if mismatch else [records[0], records[2], records[-1]]
        records[0]["scenario"] = "fresh-mv3"
        records[1]["stage"] = "fresh Safari MV3"
        records[-1]["completedStages"] = 0 if mismatch else 1
        if mismatch: records[-2]["stage"] = 0
        return records

    def test_fresh_mv3_requires_its_own_launch_attestation_and_exact_single_stage(self):
        result = probe.validate_probe_output(encoded(self.records()), 0, scenario="fresh-mv3")
        self.assertEqual(result["result"], "PUBLIC_ARM_SAMPLE_PASSED")
        self.assertEqual(result["completedStages"], 1)
        for records in [fixture(), self.records() + [self.records()[1]]]:
            with self.subTest(records=records), self.assertRaises(ValueError):
                probe.validate_probe_output(encoded(records), 0, scenario="fresh-mv3")
        with self.assertRaises(ValueError): probe.validate_probe_output(encoded(self.records()), 0)

    def test_fresh_mv3_does_not_soften_ua_or_manifest_assertions(self):
        result = probe.validate_probe_output(encoded(self.records(mismatch=True)), 1, scenario="fresh-mv3")
        self.assertEqual(result["result"], "PUBLIC_UA_MISMATCH_OBSERVED")
        self.assertEqual(result["completedStages"], 0)
        records = self.records(); records[1]["identity"]["worker"]["version"] = "2"
        with self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0, scenario="fresh-mv3")

    def test_runner_passes_control_argument_and_records_scenario_without_changing_default(self):
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder) / "Probe.app"
            executable = bundle / "Contents/MacOS/WorkerUAProbe"
            executable.parent.mkdir(parents=True); executable.write_bytes(b"fake")
            def fake_process(command, environment, timeout, log, interrupted):
                self.assertEqual(command, [str(executable.resolve()), "--fresh-mv3"])
                output = encoded(self.records(mismatch=True)); log.write_bytes(output)
                return 1, True, output
            evidence = Path(folder) / "logs"
            with patch.object(probe.owned, "run_ua_process", side_effect=fake_process) as process, redirect_stdout(io.StringIO()):
                self.assertNotEqual(probe.run_public_mode(bundle, evidence, scenario="fresh-mv3"), 0)
                self.assertEqual(process.call_count, 1)
            self.assertEqual(json.loads((evidence / "trial-01/result.json").read_text())["scenario"], "fresh-mv3")


class MV3ChainControlTests(unittest.TestCase):
    def test_chain_requires_four_distinct_mv3_contexts_and_keeps_first_mismatch(self):
        records = fixture()
        records[0]["scenario"] = "mv3-chain"
        for index in range(4):
            records[index + 1]["stage"] = f"Safari MV3 context {index + 1}"
            records[index + 1]["identity"]["worker"]["version"] = "3"
        self.assertEqual(probe.validate_probe_output(encoded(records), 0, scenario="mv3-chain")["completedStages"], 4)
        for key, value in [("version", "2"), ("nonce", "stale-context")]:
            invalid = copy.deepcopy(records); invalid[2]["identity"]["worker"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.validate_probe_output(encoded(invalid), 0, scenario="mv3-chain")
        mismatch = copy.deepcopy(records[:3])
        mismatch[-1]["identity"]["worker"].update(startup="Bare WebKit", current="Bare WebKit")
        mismatch[-1]["startupAndCurrentMatch"] = False
        mismatch += [{"event": "failure", "stage": 1, "reason": "Worker/popup startup or current identity mismatch"},
                     dict(records[-1], completedStages=1, mismatchOrHarnessFailure=True)]
        self.assertEqual(probe.validate_probe_output(encoded(mismatch), 1, scenario="mv3-chain")["result"], "PUBLIC_UA_MISMATCH_OBSERVED")
        with self.assertRaises(ValueError): probe.validate_probe_output(encoded(records), 0)


class AdapterTests(unittest.TestCase):
    def fake_run(self, mismatch=None, exited=True, deferred=False, cleanup=True, cleanup_exited=True):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        bundle = root / "Probe.app"; executable = bundle / "Contents/MacOS/WorkerUAProbe"
        executable.parent.mkdir(parents=True); executable.write_bytes(b"not an executable")
        evidence = root / "logs"
        calls = []
        store_id = [None]
        def fake_process(command, environment, timeout, log, interrupted):
            self.assertNotIn("VANE_DATA_DIR", environment)
            if len(command) == 1:
                self.assertEqual(command, [str(executable)])
                self.assertEqual(timeout, 90)
                records = fixture(mismatch=mismatch)
                store_id[0] = records[0]["ownedDataStoreID"]
                if deferred:
                    records[-1].update(ownedStoreRemovalCallbackSucceeded=False, storeRemovalDeferredToPostExit=True)
                status, verified = (1 if mismatch is not None else 0), exited
            else:
                self.assertEqual(command, [str(executable), "--retire-store", store_id[0]])
                self.assertEqual(timeout, 20)
                records = [{"event": "retirement", "ownedDataStoreID": store_id[0],
                            "ownedStoreRemovalCallbackSucceeded": cleanup, "backendRetirementVerified": False}]
                status, verified = (0 if cleanup else 1), cleanup_exited
            output = b"x" * 70_000 + b"\n" + encoded(records)
            log.write_bytes(output); calls.append((log, output))
            return status, verified, output
        with patch.object(probe.owned, "run_ua_process", side_effect=fake_process), redirect_stdout(io.StringIO()):
            status = probe.run_public_mode(bundle, evidence)
        return status, evidence, calls

    def test_deferred_store_retirement_requires_a_verified_fresh_cleanup_process(self):
        status, evidence, calls = self.fake_run(deferred=True)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 16)
        self.assertEqual([p.name for p, _ in calls], [name for _ in range(8) for name in ("primary.log", "cleanup.log")])
        for cleanup, cleanup_exited in [(False, True), (True, False)]:
            with self.subTest(cleanup=cleanup, cleanup_exited=cleanup_exited):
                status, evidence, calls = self.fake_run(deferred=True, cleanup=cleanup, cleanup_exited=cleanup_exited)
                self.assertNotEqual(status, 0)
                self.assertEqual(len(calls), 2)
                result = json.loads(calls[0][0].with_name("result.json").read_text())
                self.assertNotEqual(result["result"], "PUBLIC_ARM_SAMPLE_PASSED")
        status, evidence, calls = self.fake_run(deferred=True, mismatch=1)
        self.assertNotEqual(status, 0)
        self.assertEqual(len(calls), 2)
        result = json.loads(calls[0][0].with_name("result.json").read_text())
        self.assertEqual(result["result"], "PUBLIC_UA_MISMATCH_OBSERVED")
        self.assertTrue(result["ownedStoreRemovalCallbackSucceeded"])

    def test_cleanup_record_must_match_the_launch_store_and_real_callback(self):
        store_id = str(uuid.uuid4())
        record = {"event": "retirement", "ownedDataStoreID": store_id,
                  "ownedStoreRemovalCallbackSucceeded": True, "backendRetirementVerified": False}
        probe.validate_retirement_output(encoded([record]), 0, store_id)
        for records, status in [([], 0), ([record, record], 0), ([record], 1)]:
            with self.subTest(status=status, records=records), self.assertRaises(ValueError):
                probe.validate_retirement_output(encoded(records), status, store_id)
        for key, value in [("ownedDataStoreID", str(uuid.uuid4())), ("ownedStoreRemovalCallbackSucceeded", False),
                           ("ownedStoreRemovalCallbackSucceeded", 1), ("backendRetirementVerified", True)]:
            invalid = dict(record); invalid[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                probe.validate_retirement_output(encoded([invalid]), 0, store_id)

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
        self.assertIn("6763e5522494e913c06d2bc7f4b0d8a8167063974b49407858f3d8eb199835e7", source)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", source)
        self.assertIn("if: ${{ always() }}", source)
        self.assertIn("${{ runner.temp }}/public-probe-logs/", source)
        self.assertIn("${{ runner.temp }}/public-probe-run.log", source)
        upload = source.split("- name: Preserve complete capped logs and scoped public evidence", 1)[1]
        self.assertNotIn("Probe.app", upload); self.assertNotIn("DataStore", upload)


if __name__ == "__main__": unittest.main()
