#!/usr/bin/env python3
"""Recorder shutdown must preserve finalization and never signal a reused PID."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("recorder", Path(__file__).with_name("record-ui-frames.py"))
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class Child:
    pid = 123
    def __init__(self, running=True):
        self.running = running
        self.signals = []
        self.waited = False
    def poll(self):
        return None if self.running else 0
    def send_signal(self, value):
        self.signals.append(value)
    def terminate(self):
        self.signals.append(signal.SIGTERM)
    def wait(self):
        self.waited = True
        self.running = False
        return 0


class ShutdownTests(unittest.TestCase):
    def stop(self, child, log, observed=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "record.log"
            path.write_text(log)
            identity = {"pid": child.pid, "start": 42, "path": "/xctrace"}
            return recorder.finish_recording(child, identity, path,
                                             lambda _: identity if observed is None else observed)
    def test_recording_stops_once_and_waits_for_save(self):
        child = Child()
        self.stop(child, "Ctrl-C to stop the recording")
        self.assertEqual(child.signals, [signal.SIGINT])
        self.assertTrue(child.waited)
    def test_time_limit_and_finalization_receive_no_second_interrupt(self):
        for log in ("Reached specified time limit, ending recording...",
                    "Stopping recording...", "Recording completed. Saving output file..."):
            with self.subTest(log=log):
                child = Child()
                self.stop(child, log)
                self.assertEqual(child.signals, [])
                self.assertTrue(child.waited)
    def test_reused_pid_is_never_signaled(self):
        child = Child()
        with self.assertRaisesRegex(RuntimeError, "identity"):
            self.stop(child, "recording", {"pid": child.pid, "start": 99, "path": "/other"})
        self.assertEqual(child.signals, [])
    def test_exited_recorder_is_left_alone(self):
        child = Child(running=False)
        self.stop(child, "recording")
        self.assertEqual(child.signals, [])
        self.assertFalse(child.waited)


class SetupFailureTests(unittest.TestCase):
    def exercise(self, lookup_fails):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            executable = path / "test-app"
            executable.write_bytes(b"isolated test executable")
            identity = {"pid": 99, "start": 42, "path": str(executable.resolve())}
            native = SimpleNamespace(process_identity=lambda _: identity)
            loader = SimpleNamespace(exec_module=lambda _: None)
            def lookup(command, **kwargs):
                if command[:2] == ["xcrun", "--find"] and lookup_fails:
                    raise OSError("injected xctrace lookup failure")
                return "/usr/bin/xctrace\n"
            child = Child()
            handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
            with patch.object(sys, "argv", ["record-ui-frames.py", "--pid", "99", "--executable", str(executable),
                                           "--output", str(path / "evidence")]), \
                 patch.object(recorder.importlib.util, "spec_from_file_location", return_value=SimpleNamespace(loader=loader)), \
                 patch.object(recorder.importlib.util, "module_from_spec", return_value=native), \
                 patch.object(recorder.subprocess, "check_output", side_effect=lookup), \
                 patch.object(recorder.subprocess, "run"), \
                 patch.object(recorder.subprocess, "Popen", side_effect=[child, OSError("injected recorder launch failure")]) as spawn:
                with self.assertRaises(OSError):
                    recorder.main()
            for sig, handler in handlers.items():
                self.assertEqual(signal.getsignal(sig), handler)
            return child, spawn
    def test_failed_tool_lookup_creates_no_child(self):
        _, spawn = self.exercise(lookup_fails=True)
        spawn.assert_not_called()
    def test_failed_recorder_launch_reaps_listener_and_restores_handlers(self):
        child, _ = self.exercise(lookup_fails=False)
        self.assertEqual(child.signals, [signal.SIGTERM])
        self.assertTrue(child.waited)


class TerminalInterruptTests(unittest.TestCase):
    def test_terminal_interrupt_reaches_recorder_exactly_once(self):
        # A disposable harness owns its own terminal-like process group, so this
        # cannot interrupt the test runner or any app. The child simulates xctrace
        # finalization before it writes "Stopping recording" to the log.
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            child_code='''import os,signal,sys,time
from pathlib import Path
root=Path(sys.argv[1]); count=0
def stop(*_):
    global count
    count+=1
signal.signal(signal.SIGINT,stop)
(root/'ready').write_text('ready')
deadline=time.monotonic()+5
while not count and time.monotonic()<deadline: time.sleep(.005)
time.sleep(.1)
(root/'count').write_text(str(count))
'''
            harness_code='''import importlib.util,os,signal,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('recorder',sys.argv[1])
recorder=importlib.util.module_from_spec(spec);spec.loader.exec_module(recorder)
root=Path(sys.argv[2]); interrupted=[]
signal.signal(signal.SIGINT,lambda *_:interrupted.append(True))
with (root/'log').open('w') as log:
    child=recorder.start_recording([sys.executable,'-c',sys.argv[3],str(root)],log)
    deadline=time.monotonic()+3
    while not (root/'ready').exists() and time.monotonic()<deadline: time.sleep(.005)
    assert (root/'ready').exists()
    os.killpg(os.getpgrp(),signal.SIGINT)
    assert interrupted
    time.sleep(.05)
    recorder.finish_recording(child,{'pid':child.pid},root/'log',lambda _: {'pid':child.pid})
'''
            run=subprocess.run([sys.executable,'-c',harness_code,str(Path(recorder.__file__)),str(root),child_code],
                               start_new_session=True,capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertEqual((root/'count').read_text(),'1')


if __name__ == "__main__":
    unittest.main()
