#!/usr/bin/env python3
"""Pure checks: no AppKit, WebKit, Swift build, or native test process."""
import copy
import hashlib
import importlib.util
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

spec = importlib.util.spec_from_file_location("native_fixture_runner", Path(__file__).with_name("run-native-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.token = "a" * 32
        self.profile = str(uuid.uuid4())
        self.directory = "/tmp/vane-search-tests-owned"
        raw = bytearray(hashlib.sha256(("Vane.WebsiteData.v1\0" + self.directory + "\0" + self.profile).encode()).digest()[:16])
        raw[:4] = b"VANE"
        raw[6] = (raw[6] & 15) | 128
        raw[8] = (raw[8] & 63) | 128
        self.record = {"schema": 1, "token": self.token,
                       "host": {"pid": 123, "start": 456, "path": "/tmp/Tests.xctest/Contents/MacOS/Tests",
                                "processName": "Tests", "bundleIdentifier": "owned.tests", "testBundlePath": "/tmp/Tests.xctest"},
                       "profiles": [{"profileID": self.profile, "dataDirectory": self.directory, "storeID": str(uuid.UUID(bytes=bytes(raw)))}]}

    def test_accepts_only_recomputed_owned_identifier(self):
        self.assertEqual(runner.validate_record(self.record, self.token), self.record)
        changed = copy.deepcopy(self.record)
        changed["profiles"][0]["storeID"] = str(uuid.uuid4())
        with self.assertRaises(ValueError): runner.validate_record(changed, self.token)

    def test_refuses_default_incognito_and_nonisolated_paths(self):
        for profile in ("00000000-0000-0000-0000-000056616e65", "00000000-0000-0000-0000-000000000001"):
            changed = copy.deepcopy(self.record)
            changed["profiles"][0]["profileID"] = profile
            with self.assertRaises(ValueError): runner.validate_record(changed, self.token)
        for path in ("/", "relative", "/tmp/a/../b", ""):
            changed = copy.deepcopy(self.record)
            changed["profiles"][0]["dataDirectory"] = path
            with self.assertRaises(ValueError): runner.validate_record(changed, self.token)

    def test_refuses_wrong_contract_or_missing_host_identity(self):
        for key, value in (("token", "b" * 32), ("schema", 2), ("host", {})):
            changed = copy.deepcopy(self.record)
            changed[key] = value
            with self.assertRaises(ValueError): runner.validate_record(changed, self.token)

    def test_private_manifest_rejects_symlink_and_permissive_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / "target"
            target.write_text("{}")
            os.chmod(target, 0o600)
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(ValueError): runner.read_private_json(link)
            os.chmod(target, 0o644)
            with self.assertRaises(ValueError): runner.read_private_json(target)

    def test_live_original_host_blocks_cleanup_but_reused_pid_does_not(self):
        identity = {key: self.record["host"][key] for key in ("pid", "start", "path")}
        with self.assertRaises(ValueError): runner.require_exited_hosts([self.record], lambda pid: identity)
        reused = dict(identity, start=999)
        runner.require_exited_hosts([self.record], lambda pid: reused)
        runner.require_exited_hosts([self.record], lambda pid: None)

    def test_cleanup_preserves_selected_backend_and_build_location(self):
        cases = (
            ["--build-system", "native", "--scratch-path", "/tmp/owned-build", "-c", "debug"],
            ["--build-system=native", "--scratch-path=/tmp/owned-build", "--configuration=release"],
        )
        for location in cases:
            with self.subTest(location=location), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp) / "manifest"
                directory.mkdir()
                commands = []
                def launch(command, **kwargs):
                    commands.append(list(command))
                    child = mock.Mock(pid=123456)
                    child.wait.return_value = 0
                    return child
                result = {"schema": 1, "token": self.token,
                          "retiredIDs": [self.record["profiles"][0]["storeID"]]}
                arguments = location + ["--jobs", "1", "--filter", "LibrarySpaceCatalogTests"]
                with (mock.patch.object(runner.sys, "platform", "darwin"),
                      mock.patch.object(runner.tempfile, "mkdtemp", return_value=str(directory)),
                      mock.patch.object(runner.uuid, "uuid4", return_value=uuid.UUID(self.token)),
                      mock.patch.object(runner, "load_records", return_value=[self.record]),
                      mock.patch.object(runner, "require_exited_hosts"),
                      mock.patch.object(runner, "finish_recorded_cleanup_host"),
                      mock.patch.object(runner, "read_private_json", return_value=result),
                      mock.patch.object(runner.subprocess, "Popen", side_effect=launch)):
                    self.assertEqual(runner.main(arguments), 0)
                self.assertEqual(commands, [
                    ["swift", "test", *arguments],
                    ["swift", "test", "--skip-build", "--filter", runner.SELECTOR, *location],
                ], "Cleanup must find the same bundle without inheriting the primary test filter")

    def test_cleanup_signals_only_exact_recorded_launch_and_verifies_exit(self):
        host = self.record["host"]
        observed = {key: host[key] for key in ("pid", "start", "path")}
        signals = []
        state = {"alive": True}
        def send(pid, signum): signals.append((pid, signum)); state["alive"] = False
        runner.stop_recorded_host(host, lambda pid: observed if state["alive"] else None, send)
        self.assertEqual(signals, [(host["pid"], signal.SIGTERM)])
        signals.clear()
        runner.stop_recorded_host(host, lambda pid: dict(observed, start=999), send)
        self.assertEqual(signals, [])
        with self.assertRaises(ValueError):
            runner.stop_recorded_host(host, lambda pid: dict(observed, path="/tmp/other-executable"), send)
        self.assertEqual(signals, [])

    def test_cleanup_revalidates_before_kill_and_reports_verified_survivor(self):
        host = self.record["host"]
        observed = {key: host[key] for key in ("pid", "start", "path")}
        signals = []
        clock = [0]
        def now(): clock[0] += 1; return clock[0]
        with self.assertRaisesRegex(ValueError, "remains running"):
            runner.stop_recorded_host(host, lambda pid: observed, lambda pid, signum: signals.append(signum), lambda seconds: None, now)
        self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL])

    def test_host_exit_at_signal_boundary_requires_verified_disappearance(self):
        host = self.record["host"]
        observed = {key: host[key] for key in ("pid", "start", "path")}
        state = {"alive": True}
        def send(pid, signum):
            state["alive"] = False
            raise ProcessLookupError("exited between identity check and signal")
        runner.stop_recorded_host(host, lambda pid: observed if state["alive"] else None, send)
        def denied(pid, signum): raise PermissionError("not authorized")
        with self.assertRaises(PermissionError): runner.stop_recorded_host(host, lambda pid: observed, denied)

    @unittest.skipUnless(sys.platform == "darwin", "Actual Darwin PID/start verification")
    def test_timed_out_fake_driver_cannot_leave_recorded_separate_child_running(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pidfile = root / "child-pid"
            child_code = "import os,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"
            # The child itself announces readiness after macOS Python's launcher exec.
            code = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[2],sys.argv[1]]); time.sleep(60)"
            driver = subprocess.Popen([sys.executable, "-c", code, str(pidfile), child_code])
            child = None
            try:
                deadline = time.monotonic() + 3
                while not pidfile.exists() and time.monotonic() < deadline: time.sleep(0.01)
                self.assertTrue(pidfile.exists())
                child = runner.process_identity(int(pidfile.read_text()))
                self.assertIsNotNone(child)
                record = copy.deepcopy(self.record)
                record["host"].update(child)
                manifest = root / "cleanup-host.json"
                manifest.write_text(json.dumps(record))
                os.chmod(manifest, 0o600)
                with self.assertRaises(subprocess.TimeoutExpired): driver.wait(timeout=0.05)
                driver.terminate()
                driver.wait(timeout=3)
                self.assertIsNotNone(runner.process_identity(child["pid"]), "Stopping only the driver must leave the separate fake host observable")
                self.assertTrue(runner.finish_recorded_cleanup_host(root, self.token))
                runner.require_exited_hosts([record])
                self.assertTrue(manifest.exists(), "Unverified/failing driver paths retain concrete ownership metadata")
            finally:
                if driver.poll() is None: driver.kill(); driver.wait()
                if child is not None: runner.stop_recorded_host(child)


class OrderingTests(unittest.TestCase):
    def test_cleanup_runs_after_primary_failure_and_primary_status_wins(self):
        for primary, cleanup, expected in ((0, 0, 0), (0, 7, 7), (5, 0, 5), (5, 7, 5), (-15, 7, 143)):
            events = []
            def invoke(command):
                events.append(command)
                return primary if command == ["primary"] else cleanup
            def exited(): events.append("host-exit-check")
            result = runner.run_commands(["primary"], ["cleanup"], invoke, exited)
            self.assertEqual(result, expected)
            self.assertEqual(events, [["primary"], "host-exit-check", ["cleanup"]])

    def test_unverified_live_host_refuses_cleanup_and_fails_successful_primary(self):
        events = []
        def invoke(command): events.append(command); return 0
        def alive(): raise ValueError("owned test host still alive")
        self.assertNotEqual(runner.run_commands(["primary"], ["cleanup"], invoke, alive), 0)
        self.assertEqual(events, [["primary"]])

    def test_real_fake_child_commands_finish_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            events = Path(temp) / "events"
            primary = [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('primary-exited\\n'); sys.exit(9)", str(events)]
            cleanup = [sys.executable, "-c", "from pathlib import Path; import sys; p=Path(sys.argv[1]); assert p.read_text()=='primary-exited\\n'; p.write_text(p.read_text()+'cleanup-exited\\n'); sys.exit(4)", str(events)]
            result = runner.run_commands(primary, cleanup, lambda command: subprocess.run(command).returncode, lambda: None)
            self.assertEqual(result, 9)
            self.assertEqual(events.read_text(), "primary-exited\ncleanup-exited\n")

    def test_primary_launch_error_still_attempts_cleanup(self):
        events = []
        def invoke(command):
            events.append(command)
            if command == ["primary"]: raise OSError("fake primary launch failed")
            return 0
        self.assertEqual(runner.run_commands(["primary"], ["cleanup"], invoke, lambda: None), 1)
        self.assertEqual(events, [["primary"], ["cleanup"]])

    def test_signalled_fake_primary_still_runs_cleanup(self):
        events = []
        primary = [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"]
        def invoke(command):
            events.append(command)
            return subprocess.run(command).returncode if command == primary else 0
        self.assertEqual(runner.run_commands(primary, ["cleanup"], invoke, lambda: None), 143)
        self.assertEqual(events[-1], ["cleanup"])


if __name__ == "__main__": unittest.main()
