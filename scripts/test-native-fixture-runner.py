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


class PrimaryTimeoutTests(unittest.TestCase):
    class Driver:
        pid = 101
        def __init__(self, ignore_term=False, ignore_kill=False):
            self.code = None
            self.ignore_term = ignore_term
            self.ignore_kill = ignore_kill
            self.events = []
        def poll(self): return self.code
        def terminate(self):
            self.events.append("driver-TERM")
            if not self.ignore_term: self.code = -15
        def kill(self):
            self.events.append("driver-KILL")
            if not self.ignore_kill: self.code = -9
        def wait(self, timeout=None):
            self.events.append(("driver-wait", timeout))
            if self.code is None: raise subprocess.TimeoutExpired(["swift", "test"], timeout)
            return self.code

    def setUp(self):
        fixture = ManifestTests()
        fixture.setUp()
        self.record = fixture.record
        self.token = fixture.token
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        os.chmod(self.directory, 0o700)
        self.private_json(self.directory / "contract.json", {"schema": 1, "token": self.token})

    def private_json(self, path, body):
        path.write_text(json.dumps(body))
        os.chmod(path, 0o600)

    def write_record(self, record):
        host = record["host"]
        self.private_json(self.directory / f'host-{host["pid"]}-{host["start"]}.json', record)

    def test_primary_timeout_unset_keeps_existing_unbounded_wait(self):
        self.assertIsNone(runner.parse_primary_timeout(None))

    def test_primary_timeout_accepts_only_finite_integer_seconds(self):
        for raw in ("1", "60", "3600"):
            with self.subTest(raw=raw): self.assertEqual(runner.parse_primary_timeout(raw), int(raw))
        for raw in ("", "0", "3601", "01", "-1", "1.0", "inf", "nan", " 1", "1\n", "１", True, 7):
            with self.subTest(raw=raw), self.assertRaises(ValueError): runner.parse_primary_timeout(raw)

    def test_all_private_records_validated_before_any_host_signal_and_driver_still_stops(self):
        self.write_record(self.record)
        bad = copy.deepcopy(self.record)
        bad["host"]["pid"] = 124
        bad["schema"] = 2
        self.write_record(bad)
        driver = self.Driver()
        with mock.patch.object(runner, "stop_recorded_host") as stop:
            with self.assertRaises(ValueError): runner.retire_timed_out_primary(driver, self.directory, self.token)
        stop.assert_not_called()
        self.assertIn("driver-TERM", driver.events)
        self.assertIsNotNone(driver.poll())
        self.assertTrue(self.directory.exists())

    def test_timeout_retires_only_recorded_hosts_after_driver_exit_and_checks_exit(self):
        self.write_record(self.record)
        driver = self.Driver()
        events = []
        load = runner.load_records
        def read(directory, token):
            events.append("validate-all")
            return load(directory, token)
        def stop(host):
            self.assertIsNotNone(driver.poll(), "The driver must not launch another host after the snapshot")
            events.append(("stop", host["pid"]))
        with mock.patch.object(runner, "load_records", side_effect=read), \
             mock.patch.object(runner, "stop_recorded_host", side_effect=stop), \
             mock.patch.object(runner, "require_exited_hosts", side_effect=lambda records: events.append("verify-exit")):
            runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertEqual(events, ["validate-all", "validate-all", ("stop", 123), "verify-exit"])
        self.assertEqual(driver.events, ["driver-TERM", ("driver-wait", 5)])
        self.assertTrue(self.directory.exists())

    def test_no_host_identity_is_inconclusive_and_driver_is_bounded(self):
        driver = self.Driver(ignore_term=True)
        with self.assertRaisesRegex(ValueError, "host"):
            runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertEqual(driver.events, ["driver-TERM", ("driver-wait", 5), "driver-KILL", ("driver-wait", 5)])
        survivor = self.Driver(ignore_term=True, ignore_kill=True)
        with self.assertRaises(subprocess.TimeoutExpired): runner.stop_primary_driver(survivor)
        self.assertEqual(survivor.events[-1], ("driver-wait", 5))
        exited = self.Driver(); exited.code = 0
        runner.stop_primary_driver(exited)
        self.assertEqual(exited.events, [])

    def test_changed_executable_refuses_host_signal_and_preserves_manifest(self):
        self.write_record(self.record)
        driver = self.Driver()
        changed = {"pid": 123, "start": self.record["host"]["start"], "path": "/tmp/unrelated-user-app"}
        real_stop = runner.stop_recorded_host
        with mock.patch.object(runner, "stop_recorded_host",
                               side_effect=lambda host: real_stop(host, identity=lambda pid: changed, send=mock.Mock())), \
             mock.patch.object(runner, "require_exited_hosts", side_effect=ValueError("changed host not exited")):
            with self.assertRaisesRegex(ValueError, "identity changed"):
                runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertIsNotNone(driver.poll())
        self.assertTrue(list(self.directory.glob("host-*.json")))

    def test_pid_reuse_is_not_signaled_and_other_recorded_host_is_still_checked(self):
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        self.write_record(self.record); self.write_record(second)
        identities = {
            123: {"pid": 123, "start": 999, "path": "/tmp/unrelated-user-app"},
            124: {"pid": 124, "start": second["host"]["start"], "path": second["host"]["path"]}}
        sent = []
        def send(pid, sig): sent.append((pid, sig)); identities[pid] = None
        real_stop, real_exited = runner.stop_recorded_host, runner.require_exited_hosts
        with mock.patch.object(runner, "stop_recorded_host", side_effect=lambda host: real_stop(host, identity=lambda pid: identities[pid], send=send)), \
             mock.patch.object(runner, "require_exited_hosts", side_effect=lambda records: real_exited(records, identity=lambda pid: identities[pid])):
            runner.retire_timed_out_primary(self.Driver(), self.directory, self.token)
        self.assertEqual(sent, [(124, signal.SIGTERM)])

    def main_mocks(self, timeout, retirement_error=None, primary_timeout=True, cleanup_status=0, checked_records=None, retired_records=None, real_retirement=False):
        self.directory.mkdir(mode=0o700, exist_ok=True)
        fixed = uuid.UUID(self.token)
        primary = self.Driver() if real_retirement else mock.Mock()
        if not real_retirement:
            primary.wait.side_effect = subprocess.TimeoutExpired(["swift", "test"], 2) if primary_timeout else None
            primary.wait.return_value = 0
        cleanup = mock.Mock(); cleanup.wait.return_value = cleanup_status
        expected = sorted({entry["storeID"].lower() for record in ([self.record] if checked_records is None else checked_records) for entry in record["profiles"]})
        retired = [self.record] if retired_records is None else retired_records
        checked = [self.record] if checked_records is None else checked_records
        retirement = {"wraps": runner.retire_timed_out_primary} if real_retirement else {
            "side_effect": retirement_error, "return_value": retired}
        snapshots = {"side_effect": [retired, retired, checked]} if real_retirement else {"return_value": checked}
        # The full orchestration is exercised without any child process or signal.
        with mock.patch.object(runner.sys, "platform", "darwin"), \
             mock.patch.dict(runner.os.environ, {runner.PRIMARY_TIMEOUT_ENV: timeout} if timeout is not None else {}, clear=True), \
             mock.patch.object(runner.tempfile, "mkdtemp", return_value=str(self.directory)), \
             mock.patch.object(runner.uuid, "uuid4", return_value=fixed), \
             mock.patch.object(runner.subprocess, "Popen", side_effect=[primary, cleanup]) as popen, \
             mock.patch.object(runner, "retire_timed_out_primary", **retirement) as retire, \
             mock.patch.object(runner, "load_records", **snapshots), \
             mock.patch.object(runner, "stop_recorded_host"), \
             mock.patch.object(runner, "require_exited_hosts"), \
             mock.patch.object(runner, "finish_recorded_cleanup_host", return_value=True), \
             mock.patch.object(runner, "read_private_json", return_value={"schema": 1, "token": self.token, "retiredIDs": expected}):
            code = runner.main(["--skip-build", "--jobs", "1"])
        return code, primary, cleanup, popen.call_count, retire

    def test_primary_timeout_124_survives_cleanup_failure_and_uses_existing_90_second_cleanup(self):
        code, primary, cleanup, count, retire = self.main_mocks("2", cleanup_status=7)
        self.assertEqual(code, 124)
        primary.wait.assert_called_once_with(timeout=2)
        cleanup.wait.assert_called_once_with(timeout=90)
        self.assertEqual(count, 2)
        retire.assert_called_once()

    def test_invalid_opt_in_fails_before_any_manifest_or_driver_is_created(self):
        for value in ("", "0", "3601", "1.5"):
            with self.subTest(value=value), mock.patch.object(runner.sys, "platform", "darwin"), \
                 mock.patch.dict(runner.os.environ, {runner.PRIMARY_TIMEOUT_ENV: value}, clear=True), \
                 mock.patch.object(runner.tempfile, "mkdtemp") as directory, \
                 mock.patch.object(runner.subprocess, "Popen") as popen:
                with self.assertRaises(ValueError): runner.main(["--skip-build"])
                directory.assert_not_called()
                popen.assert_not_called()

    def test_late_invalid_record_is_revalidated_after_driver_exit_before_any_host_signal(self):
        driver = self.Driver()
        with mock.patch.object(runner, "load_records", side_effect=[[self.record], ValueError("late invalid record")]), \
             mock.patch.object(runner, "stop_recorded_host") as stop:
            with self.assertRaisesRegex(ValueError, "late invalid record"):
                runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertIsNotNone(driver.poll())
        stop.assert_not_called()

    def test_fresh_snapshot_cannot_drop_one_known_host_while_another_remains(self):
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        driver = self.Driver()
        with mock.patch.object(runner, "load_records", side_effect=[[self.record, second], [second]]), \
             mock.patch.object(runner, "stop_recorded_host") as stop, \
             mock.patch.object(runner, "require_exited_hosts") as exited:
            with self.assertRaisesRegex(ValueError, "lost|changed"):
                runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertIsNotNone(driver.poll())
        stop.assert_not_called()
        exited.assert_not_called()
        self.assertTrue(self.directory.exists())

    def test_fresh_snapshot_cannot_replace_an_immutable_known_host_identity(self):
        for field, value in [("pid", 124), ("start", 999), ("path", "/tmp/replacement.xctest/Contents/MacOS/Tests"),
                             ("testBundlePath", "/tmp/replacement.xctest"), ("processName", "Changed"),
                             ("bundleIdentifier", "changed.tests")]:
            changed = copy.deepcopy(self.record); changed["host"][field] = value
            driver = self.Driver()
            with self.subTest(field=field), \
                 mock.patch.object(runner, "load_records", side_effect=[[self.record], [changed]]), \
                 mock.patch.object(runner, "stop_recorded_host") as stop, \
                 mock.patch.object(runner, "require_exited_hosts"):
                with self.assertRaisesRegex(ValueError, "lost|changed"):
                    runner.retire_timed_out_primary(driver, self.directory, self.token)
                self.assertIsNotNone(driver.poll())
                stop.assert_not_called()

    def test_fresh_snapshot_allows_added_hosts_and_profile_entries(self):
        expanded = copy.deepcopy(self.record)
        profile_fixture = ManifestTests(); profile_fixture.setUp()
        expanded["profiles"].append(copy.deepcopy(profile_fixture.record["profiles"][0]))
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        stopped = []
        with mock.patch.object(runner, "load_records", side_effect=[[self.record], [expanded, second]]), \
             mock.patch.object(runner, "stop_recorded_host", side_effect=lambda host: stopped.append(host["pid"])), \
             mock.patch.object(runner, "require_exited_hosts") as exited:
            runner.retire_timed_out_primary(self.Driver(), self.directory, self.token)
        self.assertEqual(stopped, [123, 124])
        exited.assert_called_once_with([expanded, second])

    def test_fresh_snapshot_cannot_drop_one_known_backend_while_another_remains(self):
        expanded = copy.deepcopy(self.record)
        profile_fixture = ManifestTests(); profile_fixture.setUp()
        expanded["profiles"].append(copy.deepcopy(profile_fixture.record["profiles"][0]))
        reduced = copy.deepcopy(expanded); reduced["profiles"].pop(0)
        driver = self.Driver()
        with mock.patch.object(runner, "load_records", side_effect=[[expanded], [reduced]]), \
             mock.patch.object(runner, "stop_recorded_host") as stop, \
             mock.patch.object(runner, "require_exited_hosts") as exited:
            with self.assertRaisesRegex(ValueError, "backend|profile"):
                runner.retire_timed_out_primary(driver, self.directory, self.token)
        self.assertIsNotNone(driver.poll())
        stop.assert_not_called()
        exited.assert_not_called()
        self.assertTrue(self.directory.exists())

    def test_final_cleanup_admission_cannot_drop_a_verified_host(self):
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        code, primary, cleanup, count, retire = self.main_mocks(
            "2", retired_records=[self.record, second], checked_records=[second])
        self.assertEqual(code, 124)
        self.assertEqual(count, 1)
        cleanup.wait.assert_not_called()
        self.assertTrue(self.directory.exists())

    def test_final_cleanup_admission_cannot_change_a_verified_host_identity(self):
        for field, value in [("pid", 124), ("start", 999), ("path", "/tmp/replacement.xctest/Contents/MacOS/Tests"),
                             ("testBundlePath", "/tmp/replacement.xctest"), ("processName", "Changed"),
                             ("bundleIdentifier", "changed.tests")]:
            changed = copy.deepcopy(self.record); changed["host"][field] = value
            with self.subTest(field=field):
                code, primary, cleanup, count, retire = self.main_mocks(
                    "2", retired_records=[self.record], checked_records=[changed])
                self.assertEqual(code, 124)
                self.assertEqual(count, 1)
                cleanup.wait.assert_not_called()
                self.assertTrue(self.directory.exists())

    def test_final_cleanup_admission_cannot_drop_a_verified_backend(self):
        expanded = copy.deepcopy(self.record)
        profile_fixture = ManifestTests(); profile_fixture.setUp()
        expanded["profiles"].append(copy.deepcopy(profile_fixture.record["profiles"][0]))
        reduced = copy.deepcopy(expanded); reduced["profiles"].pop(0)
        code, primary, cleanup, count, retire = self.main_mocks(
            "2", retired_records=[expanded], checked_records=[reduced])
        self.assertEqual(code, 124)
        self.assertEqual(count, 1)
        cleanup.wait.assert_not_called()
        self.assertTrue(self.directory.exists())

    def test_real_retirement_snapshot_remains_required_at_final_cleanup_admission(self):
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        second["profiles"] = []
        code, primary, cleanup, count, retire = self.main_mocks(
            "2", retired_records=[self.record, second], checked_records=[second], real_retirement=True)
        self.assertEqual(code, 124)
        self.assertEqual(count, 1)
        self.assertIsNotNone(primary.poll())
        self.assertIn("driver-TERM", primary.events)
        cleanup.wait.assert_not_called()
        self.assertTrue(self.directory.exists())

    def test_final_cleanup_admission_accepts_appended_hosts_and_backends(self):
        expanded = copy.deepcopy(self.record)
        profile_fixture = ManifestTests(); profile_fixture.setUp()
        expanded["profiles"].append(copy.deepcopy(profile_fixture.record["profiles"][0]))
        second = copy.deepcopy(self.record); second["host"]["pid"] = 124
        code, primary, cleanup, count, retire = self.main_mocks(
            "2", retired_records=[self.record], checked_records=[expanded, second])
        self.assertEqual(code, 124)
        self.assertEqual(count, 2)
        cleanup.wait.assert_called_once_with(timeout=90)
        self.assertFalse(self.directory.exists())

    def test_unverified_timeout_identity_blocks_cleanup_and_retains_manifest(self):
        code, primary, cleanup, count, retire = self.main_mocks("2", retirement_error=ValueError("unverified host"))
        self.assertEqual(code, 124)
        self.assertEqual(count, 1)
        self.assertTrue(self.directory.exists())
        cleanup.wait.assert_not_called()

    def test_disappeared_timeout_manifest_records_cannot_be_treated_as_verified_empty_cleanup(self):
        code, primary, cleanup, count, retire = self.main_mocks("2", checked_records=[])
        self.assertEqual(code, 124)
        self.assertTrue(self.directory.exists())
        self.assertEqual(count, 1)
        cleanup.wait.assert_not_called()

    def test_disabled_timeout_leaves_primary_wait_and_cleanup_behavior_unchanged(self):
        code, primary, cleanup, count, retire = self.main_mocks(None, primary_timeout=False)
        self.assertEqual(code, 0)
        primary.wait.assert_called_once_with(timeout=None)
        cleanup.wait.assert_called_once_with(timeout=90)
        retire.assert_not_called()
        self.assertEqual(count, 2)

    def test_timeout_diagnostic_error_keeps_primary_124_but_still_calls_cleanup_guard(self):
        events = []
        def invoke(command):
            events.append(command)
            if command == ["primary"]: raise runner.PrimaryTimeoutError("ownership unverified")
            return 7
        result = runner.run_commands(["primary"], ["cleanup"], invoke, lambda: events.append("guard"))
        self.assertEqual(result, 124)
        self.assertEqual(events, [["primary"], "guard", ["cleanup"]])


if __name__ == "__main__": unittest.main()
