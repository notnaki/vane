#!/usr/bin/env python3
"""Pure runner guards. Never build or launch Vane, AppKit, or WebKit."""
import copy
from contextlib import redirect_stdout
from argparse import Namespace
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("browser_smoke", Path(__file__).with_name("check-browser-smoke.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

LABELS = ["UA normal-loop host", "UA normal-loop safari-mv2", "UA normal-loop safari-mv3",
          "UA normal-loop custom-mv3", "UA normal-loop safari-after-custom-mv3"]


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "extensioncheck-results.json"
        self.report = {"profileID": str(uuid.uuid4()), "findings": [
            {"workflow": label, "result": "VERIFIED", "detail": "Verified real identity"} for label in LABELS]}
        self.report["findings"][0]["detail"] = "finishedLaunching=true; appRunning=true; WebKit=123; OS=Version 26.6.2"

    def write(self, report=None):
        self.path.write_text(json.dumps(self.report if report is None else report))
        return self.path

    def test_exact_positive_protocol_is_required(self):
        self.assertEqual(runner.validate_ua_report(self.write()), self.report["profileID"])
        for field, value in [("profileID", "not-a-uuid"), ("findings", []), ("findings", self.report["findings"] * 2)]:
            changed = copy.deepcopy(self.report); changed[field] = value
            with self.subTest(field=field, value=str(value)[:30]), self.assertRaises(ValueError):
                runner.validate_ua_report(self.write(changed))

    def test_verified_echo_is_five_unique_bounded_json_records_with_real_host_metadata(self):
        self.report["findings"][0]["detail"] = "finishedLaunching=true; appRunning=true; WebKit=22624.5.1+; OS=Version 26.6.2 (Build 25G83)"
        self.report["findings"][1]["detail"] = 'Quoted "identity" \\ path\nCafé\t' * 100
        output = io.StringIO()
        with redirect_stdout(output):
            profile = runner.validate_ua_report(self.write(), echo_verified=True)
        self.assertEqual(profile, self.report["profileID"])
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 5)
        records = [json.loads(line) for line in lines]
        self.assertEqual(records, self.report["findings"])
        self.assertEqual(len({r["workflow"] for r in records}), 5)
        self.assertTrue(all(r["result"] == "VERIFIED" for r in records))
        self.assertLessEqual(len(output.getvalue().encode()), 5 * (6 * 8192 + 512))
        silent = io.StringIO()
        with redirect_stdout(silent): self.assertEqual(runner.validate_ua_report(self.path), profile)
        self.assertEqual(silent.getvalue(), "")

    def test_invalid_report_never_emits_partial_positive_records(self):
        for mutation in ["last-failed", "last-duplicate", "host-unavailable"]:
            report = copy.deepcopy(self.report)
            if mutation == "last-failed": report["findings"][-1]["result"] = "FAILED"
            elif mutation == "last-duplicate": report["findings"][-1]["workflow"] = LABELS[0]
            else: report["findings"][0]["detail"] = "finishedLaunching=true; appRunning=true; WebKit=unavailable; OS=Version 26.6.2"
            output = io.StringIO()
            with self.subTest(mutation=mutation), redirect_stdout(output):
                with self.assertRaises(ValueError): runner.validate_ua_report(self.write(report), echo_verified=True)
                self.assertEqual(output.getvalue(), "")

    def test_host_version_requires_concrete_numeric_components(self):
        for version in ["unavailable", "", ".", "123..456", "123.beta", "+", "123+extra"]:
            report = copy.deepcopy(self.report)
            report["findings"][0]["detail"] = "finishedLaunching=true; appRunning=true; WebKit=" + version + "; OS=Version 26.6.2"
            with self.subTest(version=version), self.assertRaises(ValueError): runner.validate_ua_report(self.write(report))

    def test_missing_duplicate_unknown_failed_and_unavailable_are_rejected(self):
        for mutation in ["missing", "duplicate", "unknown", "FAILED", "UNAVAILABLE", "launch"]:
            report = copy.deepcopy(self.report)
            if mutation == "missing": report["findings"].pop()
            elif mutation == "duplicate": report["findings"][1]["workflow"] = LABELS[0]
            elif mutation == "unknown": report["findings"][1]["workflow"] = "Other successful check"
            elif mutation == "launch": report["findings"][0]["detail"] = "finishedLaunching=false; appRunning=true"
            else: report["findings"][2]["result"] = mutation
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runner.validate_ua_report(self.write(report))

    def test_no_follow_bounded_regular_report_read(self):
        with self.assertRaises(ValueError): runner.validate_ua_report(self.path)
        target = self.write()
        link = target.with_name("link"); link.symlink_to(target)
        with self.assertRaises(ValueError): runner.validate_ua_report(link)
        self.path.write_bytes(b" " * 65_537)
        with self.assertRaises(ValueError): runner.validate_ua_report(self.path)
        fifo = self.path.with_name("pipe"); os.mkfifo(fifo)
        with self.assertRaises(ValueError): runner.validate_ua_report(fifo)

    def test_cleanup_requires_positive_anchored_count(self):
        self.assertIsNone(runner.validate_ua_cleanup(b"PASS browsercheck cleanup: 1 temporary WebKit stores unregistered\n"))
        for raw in [b"", b"PASS browsercheck cleanup: 0 temporary WebKit stores unregistered\n",
                    b"prefix PASS browsercheck cleanup: 1 temporary WebKit stores unregistered\n",
                    b"PASS browsercheck cleanup: 1 temporary WebKit stores unregistered EXTRA\n"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError): runner.validate_ua_cleanup(raw)


class ProcessTests(unittest.TestCase):
    host = {"pid": 123, "start": 456, "path": "/tmp/owned.app/Contents/MacOS/vane"}

    class Process:
        def __init__(self): self.code = None
        def poll(self): return self.code

    def test_signals_exact_launch_and_requires_exit(self):
        process = self.Process(); signals = []
        def send(pid, sig): signals.append((pid, sig)); process.code = -sig
        runner.stop_ua_launch(self.host, process, lambda pid: self.host, send, lambda _: None, lambda: 0)
        self.assertEqual(signals, [(123, signal.SIGTERM)])
        self.assertIsNotNone(process.poll())

    def test_pid_start_or_executable_change_never_receives_signal(self):
        for changed in [dict(self.host, start=999), dict(self.host, path="/tmp/user.app/vane"), None]:
            signals = []
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                runner.stop_ua_launch(self.host, self.Process(), lambda pid: changed,
                                      lambda *args: signals.append(args), lambda _: None, lambda: 0)
            self.assertEqual(signals, [])

    def test_revalidates_between_term_and_kill_and_bounds_survivor(self):
        clock = [0]; signals = []; current = [self.host]
        def now(): clock[0] += 1; return clock[0]
        def send(pid, sig):
            signals.append(sig)
            current[0] = dict(self.host, path="/tmp/replaced-executable")
        with self.assertRaises(ValueError):
            runner.stop_ua_launch(self.host, self.Process(), lambda pid: current[0], send, lambda _: None, now)
        self.assertEqual(signals, [signal.SIGTERM])
        clock[0] = 0; signals.clear()
        with self.assertRaises(ValueError):
            runner.stop_ua_launch(self.host, self.Process(), lambda pid: self.host,
                                  lambda pid, sig: signals.append(sig), lambda _: None, now)
        self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL])

    def test_esrch_race_requires_reaped_child_and_permission_error_is_not_ignored(self):
        process = self.Process()
        def gone(pid, sig): process.code = -sig; raise ProcessLookupError()
        runner.stop_ua_launch(self.host, process, lambda pid: self.host, gone, lambda _: None, lambda: 0)
        def denied(pid, sig): raise PermissionError()
        with self.assertRaises(PermissionError):
            runner.stop_ua_launch(self.host, self.Process(), lambda pid: self.host, denied, lambda _: None, lambda: 0)


class SequencingTests(unittest.TestCase):
    def test_original_cohort_filter_selects_exact_original_six_ua_and_two_password_cases(self):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml"
        source = workflow.read_text()
        section = source.split("- name: Bounded reproduction of original worker and continuation cases", 1)[1].split("- name:", 1)[0]
        pattern = re.search(r"--filter '([^']+)'", section).group(1)
        original_ua = ["testBrowserAndExtensionPoolsShareOwnershipWithoutSharingProfileStorage",
            "testDefaultSafariIdentityReachesBackgroundAndPopupBeforeTheirScriptsRun",
            "testDevelopChangeUpdatesLiveBackgroundAndRecreatedPopupWithoutChangingAccess",
            "testExplicitCustomIdentitySurvivesHostRestoration",
            "testRepeatedBackgroundTeardownReleasesRetiredHostsControllersAndContexts",
            "testServiceWorkerIdentityFollowsSelectionWhenSharedPoolIsReused"]
        original_pw = ["testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep", "testReplacementUsernameFormCannotReuseExplicitSelection"]
        for cls, names in [("ExtensionUserAgentTests", original_ua), ("PasswordAutofillTests", original_pw)]:
            for name in names:
                case = "VaneTests." + cls + "/" + name
                self.assertIsNotNone(re.fullmatch(pattern, case), case)
                self.assertIsNone(re.fullmatch(pattern, case + "Extra"))
        for case in ["VaneTests.ExtensionUserAgentTests/testExtensionFixtureCompletesAppKitLaunchAcrossIdle",
                     "VaneTests.ExtensionUserAgentTests/testNewUnreviewedCase", "OtherTests.ExtensionUserAgentTests/" + original_ua[0],
                     "VaneTests.PasswordAutofillTests/testOtherCase"]:
            self.assertIsNone(re.fullmatch(pattern, case), case)

    def test_opt_in_mode_rejects_every_other_smoke_mode(self):
        clean = dict(extension_user_agent_only=True, app=None, distribution=False, lifecycle=False,
                     public_media=False, crash_recovery=False)
        runner.validate_ua_options(Namespace(**clean))
        for key in ["app", "distribution", "lifecycle", "public_media", "crash_recovery"]:
            changed = dict(clean); changed[key] = Path("/tmp/existing.app") if key == "app" else True
            with self.subTest(key=key), self.assertRaises(ValueError): runner.validate_ua_options(Namespace(**changed))

    def test_cleanup_after_verified_exit_and_primary_failure_wins(self):
        for primary, cleanup, expected in [(0, 0, 0), (0, 7, 7), (5, 0, 5), (5, 7, 5), (-15, 0, 143)]:
            events = []
            def invoke(phase):
                events.append(phase)
                return (primary if phase == "primary" else cleanup), True
            self.assertEqual(runner.run_ua_commands(invoke), expected)
            self.assertEqual(events, ["primary", "cleanup"])

    def test_unverified_primary_exit_blocks_cleanup(self):
        calls = []
        def invoke(phase): calls.append(phase); return 0, False
        self.assertNotEqual(runner.run_ua_commands(invoke), 0)
        self.assertEqual(calls, ["primary"])

    def test_first_failed_trial_stops_without_retry(self):
        calls = []
        def trial(number): calls.append(number); return 7 if number == 3 else 0
        self.assertEqual(runner.run_ua_trials(trial), 7)
        self.assertEqual(calls, [1, 2, 3])
        calls.clear()
        self.assertEqual(runner.run_ua_trials(lambda n: calls.append(n) or 0), 0)
        self.assertEqual(calls, list(range(1, 9)))
        with self.assertRaises(ValueError): runner.run_ua_trials(lambda _: 0, count=9)

    def test_output_poll_is_bounded_and_never_waits_for_open_writer(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read); self.addCleanup(os.close, write)
        os.set_blocking(read, False)
        os.write(write, b"private" * 50)
        output = bytearray()
        consumed, overflow = runner.drain_ua_output(read, output, limit=64)
        self.assertEqual(consumed, 350)
        self.assertEqual(len(output), 64)
        self.assertTrue(overflow)
        self.assertEqual(runner.drain_ua_output(read, output, limit=64), (0, False))

    def test_output_poll_leaves_unread_data_for_next_poll(self):
        with tempfile.TemporaryFile() as source:
            source.write(b"x" * 20_000); source.seek(0)
            output = bytearray()
            self.assertEqual(runner.drain_ua_output(source.fileno(), output), (16_384, False))
            self.assertEqual(runner.drain_ua_output(source.fileno(), output), (3616, False))
            self.assertEqual(len(output), 20_000)


if __name__ == "__main__": unittest.main()
