#!/usr/bin/env python3
"""Ownership and control-calibration tests; no AppKit or native host is launched."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location("password_preflight", Path(__file__).with_name("password-document-preflight.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
UI = {"pid": 41, "start": 100, "path": "/owned/VanePackageTests.xctest/Contents/MacOS/VanePackageTests"}
CONTENT = {"pid": 42, "start": 200, "path": "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"}
phase_spec = importlib.util.spec_from_file_location("password_phases", Path(__file__).with_name("password-document-phases.py"))
phases = importlib.util.module_from_spec(phase_spec)
phase_spec.loader.exec_module(phases)


class Runner:
    def __init__(self): self.live = {41: UI.copy(), 42: CONTENT.copy()}
    def process_identity(self, pid): return self.live.get(pid)
    def load_records(self, directory, token): return [{"host": UI}]


class DiagnosticSafety(unittest.TestCase):
    def record(self, token="one", phase="pending"):
        return {"token": token, "path": "password", "phase": phase, "ui": UI.copy(), "content": CONTENT.copy()}

    def test_manifest_identity_and_current_launch_are_both_required(self):
        runner = Runner()
        record = self.record()
        self.assertEqual(p.authorize_claim(record, "content", [{"host": UI}], runner.process_identity), CONTENT)
        with self.assertRaisesRegex(ValueError, "manifest"):
            p.authorize_claim(record, "ui", [], runner.process_identity)
        runner.live[41] = dict(UI, start=101)
        with self.assertRaisesRegex(ValueError, "no longer current"):
            p.authorize_claim(record, "content", [{"host": UI}], runner.process_identity)

    def test_kernel_path_and_canonical_executable_alias_match_without_ignoring_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            target, alias = Path(directory) / "executable", Path(directory) / "alias"
            target.touch()
            alias.symlink_to(target)
            claim, observed = dict(UI, path=str(alias)), dict(UI, path=str(target))
            self.assertTrue(p.same_identity(claim, observed))
            self.assertFalse(p.same_identity(claim, dict(observed, start=101)))

    def test_content_reuse_wrong_executable_and_missing_receipt_are_refused(self):
        for change in ({"start": 201}, {"path": "/user/WebContent"}):
            runner = Runner()
            runner.live[42] = dict(CONTENT, **change)
            record = self.record()
            if "path" in change: record["content"] = runner.live[42]
            with self.assertRaises(ValueError):
                p.authorize_claim(record, "content", [{"host": UI}], runner.process_identity)
        with self.assertRaisesRegex(ValueError, "pending"):
            p.authorize_claim(self.record(phase="before-load"), "content", [{"host": UI}], Runner().process_identity)

    def test_actual_macos26_cryptex_webkit_path_is_supported(self):
        runner, record = Runner(), self.record()
        runner.live[42] = dict(CONTENT, path="/System/Volumes/Preboot/Cryptexes/OS" + CONTENT["path"])
        record["content"] = runner.live[42]
        self.assertEqual(p.authorize_claim(record, "content", [{"host": UI}], runner.process_identity), runner.live[42])

    def test_commit_cancels_before_sampling_and_fresh_receipt_is_required(self):
        captured = []
        def capture(*args): captured.append(args[0]); return {"status": "captured"}
        with tempfile.TemporaryDirectory() as directory:
            c = p.Collector(Path(directory), Runner(), capture)
            c.manifest = (Path(directory), "contract")
            c.line(p.PROCESS + json.dumps(self.record(phase="before-load")), now=0)
            c.line(p.COMMIT + "one", now=0.2)
            c.tick(now=1)
            self.assertEqual(c.finish(), [])
            self.assertEqual(captured, [])
            c = p.Collector(Path(directory), Runner(), capture)
            c.manifest = (Path(directory), "contract")
            c.line(p.PROCESS + json.dumps(self.record(phase="before-load")), now=0)
            c.line(p.PROCESS + json.dumps(self.record()), now=0.5)
            c.tick(now=1.1)
            report = c.report()
            events = report["events"]
            self.assertEqual(len(captured), 1)  # UI only; stale content is never sampled.
            self.assertTrue(any("stale" in row.get("reason", "") for row in events))
            self.assertFalse(report["valid"], "collector refusal must not count as a passing diagnostic")

    def test_delayed_navigation_samples_only_two_roles_once_and_stops_at_cap(self):
        captured = []
        def capture(claim, output, cancel, identity):
            captured.append(claim)
            return {"status": "captured"}
        with tempfile.TemporaryDirectory() as directory:
            c = p.Collector(Path(directory), Runner(), capture)
            c.manifest = (Path(directory), "contract")
            for n in range(8):
                token = str(n)
                c.line(p.PROCESS + json.dumps(self.record(token, "before-load")), now=0)
                c.line(p.PROCESS + json.dumps(self.record(token)), now=0.5)
            c.tick(now=0.8)
            c.tick(now=0.9)
            events = c.finish()
            self.assertEqual(len(captured), p.MAX_SAMPLES)
            self.assertEqual(len(events), p.MAX_SAMPLES)
            self.assertEqual({row["role"] for row in events}, {"ui", "content"})

    def test_late_commit_without_fresh_content_receipt_is_incomplete(self):
        def capture(*args): return {"status": "captured"}
        with tempfile.TemporaryDirectory() as directory:
            c = p.Collector(Path(directory), Runner(), capture)
            c.manifest = (Path(directory), "contract")
            c.line(p.PROCESS + json.dumps(self.record(phase="before-load")), now=0)
            c.tick(now=0.8)
            c.line(p.COMMIT + "one", now=2)
            report = c.report()
            content = [row for row in report["events"] if row["role"] == "content"]
            self.assertEqual(len(content), 1)
            self.assertEqual(content[0]["status"], "incomplete")
            self.assertIn("fresh", content[0]["reason"])
            self.assertFalse(report["valid"])

    def test_sampler_bound_cancels_only_owned_popen_child_and_retains_evidence(self):
        class Sampler:
            def __init__(self): self.signals = []; self.status = None
            def poll(self): return self.status
            def terminate(self): self.signals.append("terminate"); self.status = -15
            def kill(self): self.signals.append("kill"); self.status = -9
            def wait(self, timeout): return self.status
        sampler = Sampler()
        clock = [0.0]
        def now(): clock[0] += 1; return clock[0]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sample.txt"
            def launch(arguments, **kwargs):
                self.assertEqual(arguments[:3], ["/usr/bin/sample", "42", "1"])
                Path(arguments[-1]).write_bytes(b"bounded diagnostic evidence\n")
                return sampler
            result = p.capture_process(CONTENT, output, threading.Event(), Runner().process_identity,
                                       counters=lambda pid: {"pid": pid}, popen=launch, now=now, pause=lambda _: None)
            self.assertEqual(result["status"], "incomplete")
            self.assertIn("bound", result["reason"])
            self.assertEqual(sampler.signals, ["terminate"])
            self.assertIn("evidence", output.read_text())
            self.assertIn("after", result)

    def test_identity_change_before_sampler_launch_refuses_without_process(self):
        with tempfile.TemporaryDirectory() as directory:
            def forbidden(*args, **kwargs): self.fail("must not launch a sampler")
            result = p.capture_process(CONTENT, Path(directory) / "sample", threading.Event(),
                                       lambda pid: dict(CONTENT, start=201), popen=forbidden)
            self.assertEqual(result["status"], "refused")

    def test_sampler_nonzero_and_empty_output_are_incomplete(self):
        class Sampler:
            def __init__(self, status): self.status = status
            def poll(self): return self.status
            def wait(self, timeout): return self.status
        for status, text in ((1, b"sample failed"), (0, b"")):
            with tempfile.TemporaryDirectory() as directory:
                def launch(arguments, **kwargs):
                    Path(arguments[-1]).write_bytes(text)
                    return Sampler(status)
                result = p.capture_process(CONTENT, Path(directory) / "sample", threading.Event(),
                    Runner().process_identity, counters=lambda _: {}, popen=launch)
                self.assertEqual(result["status"], "incomplete")

    def test_selected_execution_rejects_empty_duplicate_skipped_and_crashed_results(self):
        target = "Test Case '-[VaneTests.PasswordAutofillTests testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep]' "
        valid = target + "started.\n" + target + "passed (1 seconds).\n"
        self.assertTrue(p.verify_execution(valid, [p.TARGET], set())["valid"])
        self.assertFalse(p.verify_execution(valid, [p.TARGET], set(), "0" * 64)["valid"])
        for invalid in ("", valid + valid, valid.replace("passed", "skipped"), valid + "Backtrace took 0.1s",
                        valid + "NATIVE TEST DRIVER pid=99 phase=cleanup\n*** Signal 11: Backtracing"):
            self.assertFalse(p.verify_execution(invalid, [p.TARGET], set())["valid"])
        other = "VaneTests.Other/testKnownLimitation"
        prior = "Test Case '-[VaneTests.Other testKnownLimitation]' "
        log = prior + "started.\n" + prior + "skipped (1 seconds).\n" + valid
        self.assertFalse(p.verify_execution(log, [other, p.TARGET], set())["valid"])
        result = p.verify_execution(log, [other, p.TARGET], {other})
        self.assertTrue(result["valid"])
        self.assertEqual(result["preserved_original_skips"], [other])

    def test_fixed_vectors_and_prefix_require_current_inventory(self):
        config = Path(__file__).with_name("password-document-preflight.json")
        value = json.loads(config.read_text())
        with tempfile.TemporaryDirectory() as directory:
            inventory = Path(directory) / "inventory"
            inventory.write_text("\n".join(value["prefix"]) + "\n")
            planned = p.plan(inventory, config)
            self.assertEqual(planned["vectors"][0]["repetitions"], 1)
            self.assertEqual(sum(arm["repetitions"] for arm in planned["vectors"]), 8)
            self.assertEqual(planned["vectors"][-1]["control"], "pending-calibration")
            inventory.write_text("\n".join(value["prefix"][1:]))
            with self.assertRaisesRegex(ValueError, "missing"):
                p.plan(inventory, config)

    def test_pending_calibration_requires_a_real_live_sampler_inside_monotonic_hold(self):
        def source(phase, stamp):
            return {'source': {'phase': phase, 'monotonicNs': stamp, 'fields': {'path': 'password'}}}
        channel = {'events': [source('calibration-held', 1000000000), source('calibration-released', 2200000000), source('commit', 2250000000)]}
        sample = {'role': 'ui', 'target_live_at_start': True, 'sampler_pid': 99,
                  'capture_started_monotonic_ns': 1800000000, 'status': 'cancelled',
                  'sample_progress_monotonic_ns': 1810000000, 'target_live_at_sample_progress': True,
                  'sampler_identity': {'pid': 99, 'start': 400, 'path': os.path.realpath('/usr/bin/sample')}}
        self.assertTrue(p.verify_pending_calibration(channel, [sample])['valid'])
        for changes in ({'target_live_at_start': False}, {'sampler_pid': None},
                        {'capture_started_monotonic_ns': 2250000000}, {'status': 'incomplete'},
                        {'target_live_at_sample_progress': False}, {'sample_progress_monotonic_ns': 2250000000},
                        {'sampler_identity': None}, {'sampler_identity': {'pid': 100, 'start': 400, 'path': '/usr/bin/sample'}},
                        {'sampler_identity': {'pid': 99, 'start': 0, 'path': '/usr/bin/sample'}},
                        {'sampler_identity': {'pid': 99, 'start': 400, 'path': '/wrong/sample'}}):
            self.assertFalse(p.verify_pending_calibration(channel, [dict(sample, **changes)])['valid'])
        self.assertFalse(p.verify_pending_calibration({'events': []}, [sample])['valid'])
        self.assertFalse(p.verify_pending_calibration(channel, [])['valid'])

    def test_actual_ancestry_breadcrumb_function_retains_state_changes_and_cap(self):
        source = (p.ROOT / "Tests/VaneTests/PasswordAutofillTests.swift").read_text()
        function = source.split("            var diagnosticContext =", 1)[1].split('            """', 1)[0]
        function = "var diagnosticContext =" + textwrap.dedent(function)
        program = """
          var sent = [], diagnosticSerial = 0;
          var window = {webkit:{messageHandlers:{vanepw:{postMessage:m=>sent.push(m)}}}};
          var topWindow = window;
        """ + function + """
          var child = {parent:window,frameElement:{isConnected:true}};
          diagnosticTrace('anchor-advance',child);
          diagnosticTrace('anchor-advance',child);
          child.frameElement.isConnected=false;
          diagnosticTrace('anchor-advance',child);
          child.parent=child;
          diagnosticTrace('anchor-advance',child);
          if(sent.length!==3) throw Error('changed ancestry evidence was suppressed');
          if(sent[2].parentSelf!==true||sent[2].frameConnected!==false) throw Error('wrong primitive state');
          for(var i=0;i<200;i++) diagnosticTrace('state'+i,child);
          if(sent.length!==96) throw Error('diagnostic cap was lost');
        """
        subprocess.run(["node", "-e", program], check=True, capture_output=True, text=True)


class LivePhaseSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.native = self.root / "native"
        self.channel = self.root / "channel"
        self.native.mkdir(mode=0o700)
        self.channel.mkdir(mode=0o700)
        self.context = {"schema": 1, "channelToken": "a" * 32,
                        "nativeDirectory": str(self.native), "nativeToken": "b" * 32}
        p.write_json(self.channel / "context.json", self.context)
        self.collector = p.Collector(self.root, Runner(), lambda *args: {"status": "captured"})
        self.reader = phases.PhaseReader(self.channel, "a" * 32, self.collector.runner, self.collector)

    def tearDown(self):
        self.collector.finish()
        if hasattr(self.reader, "close"): self.reader.close()
        self.temporary.cleanup()

    def event(self, sequence=1, **changes):
        value = {"schema": 1, "channelToken": "a" * 32, "nativeToken": "b" * 32,
                 "host": UI.copy(), "sequence": sequence, "phase": "process",
                 "wallSeconds": time.time(), "monotonicNs": time.monotonic_ns(),
                 "fields": {"token": "nav", "path": "password", "phase": "before-load",
                            "ui": UI.copy(), "content": CONTENT.copy()}}
        value.update(changes)
        return value

    def publish(self, value):
        p.write_json(self.channel / ("event-%04d.json" % value["sequence"]), value)

    def test_direct_channel_observes_live_phase_before_driver_output(self):
        value = self.event()
        self.publish(value)
        received = self.reader.poll()
        self.assertEqual(len(received), 1)
        self.assertGreaterEqual(received[0]["receiptMonotonicNs"], value["monotonicNs"])
        self.assertEqual(received[0]["source"]["monotonicNs"], value["monotonicNs"])
        self.assertIn("nav", self.collector.pending)
        self.assertEqual(self.reader.poll(), [], "an atomic record is delivered only once")
        self.assertTrue(self.reader.report()["valid"])

    def test_wrong_token_host_and_sequence_are_explicit_failures(self):
        for changes in ({"channelToken": "c" * 32}, {"nativeToken": "c" * 32},
                        {"host": dict(UI, start=999)}, {"sequence": 2}):
            with self.subTest(changes=changes):
                value = self.event(**changes)
                self.publish(value)
                self.reader.poll()
                self.assertTrue(self.reader.report()["errors"])
                self.assertFalse(self.reader.report()["valid"])
                for path in self.channel.glob("event-*.json"): path.unlink()
                if hasattr(self.reader, "close"): self.reader.close()
                self.reader = phases.PhaseReader(self.channel, "a" * 32, Runner(), self.collector)

    def test_symlink_mode_oversize_and_excess_count_are_rejected(self):
        target = self.root / "outside"
        p.write_json(target, self.event())
        event = self.channel / "event-0001.json"
        event.symlink_to(target)
        self.reader.poll()
        self.assertTrue(self.reader.report()["errors"])
        event.unlink()
        if hasattr(self.reader, "close"): self.reader.close()
        self.reader = phases.PhaseReader(self.channel, "a" * 32, Runner(), self.collector)
        self.publish(self.event())
        event.chmod(0o644)
        self.reader.poll()
        self.assertTrue(self.reader.report()["errors"])
        event.unlink()
        if hasattr(self.reader, "close"): self.reader.close()
        self.reader = phases.PhaseReader(self.channel, "a" * 32, Runner(), self.collector)
        event.write_bytes(b"x" * 16385)
        event.chmod(0o600)
        self.reader.poll()
        self.assertTrue(self.reader.report()["errors"])
        event.unlink()
        if hasattr(self.reader, "close"): self.reader.close()
        self.reader = phases.PhaseReader(self.channel, "a" * 32, Runner(), self.collector)
        for n in range(257): (self.channel / ("event-%04d.json" % (n + 1))).touch(mode=0o600)
        self.reader.poll()
        self.assertTrue(self.reader.report()["errors"])

    def test_parent_symlink_is_rejected_without_following_it(self):
        alias = self.root / "alias"
        alias.symlink_to(self.channel, target_is_directory=True)
        other = phases.PhaseReader(alias, "a" * 32, Runner(), self.collector)
        other.poll()
        self.assertTrue(other.report()["errors"])
        if hasattr(other, "close"): other.close()


if __name__ == "__main__": unittest.main()
