#!/usr/bin/env python3
"""Ownership and collection contracts; never launch apps or sample a process."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("resize_profile", Path(__file__).with_name("profile-resize-motion.py"))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.bundle = "/private/tmp/owned/.build/VanePackageTests.xctest"
        self.token = "a" * 32
        self.record = {
            "schema": 1, "token": self.token, "sidebar": True, "readyAt": 100.0,
            "testBundlePath": self.bundle,
            "ui": {"pid": 123, "start": 456, "path": "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"},
            "content": {"pid": 789, "start": 987, "path": "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"},
        }

    def test_accepts_only_the_selected_fixture_and_system_content(self):
        self.assertEqual(profile.validate_record(self.record, self.token, self.bundle), self.record)
        for key, value in (("token", "b" * 32), ("schema", 2), ("sidebar", False),
                           ("testBundlePath", "/Applications/Vane.app"), ("readyAt", float("nan"))):
            changed = dict(self.record, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                profile.validate_record(changed, self.token, self.bundle)
        for path in ("/Applications/Vane.app/Contents/MacOS/Vane", "/tmp/com.apple.WebKit.WebContent"):
            changed = copy.deepcopy(self.record)
            changed["content"]["path"] = path
            with self.assertRaises(ValueError): profile.validate_record(changed, self.token, self.bundle)

    def test_refuses_missing_reused_or_changed_process_before_sampling(self):
        captured = self.record["ui"]
        profile.require_identity(captured, lambda pid: dict(captured))
        for observed in (None, dict(captured, pid=124), dict(captured, start=457),
                         dict(captured, path="/Applications/Vane.app/Contents/MacOS/Vane")):
            with self.subTest(observed=observed), self.assertRaises(ValueError):
                profile.require_identity(captured, lambda pid: observed)

    def test_window_profile_requires_the_explicit_selected_motion(self):
        window = dict(self.record, sidebar=False)
        self.assertEqual(profile.validate_record(window, self.token, self.bundle, sidebar=False), window)
        with self.assertRaises(ValueError):
            profile.validate_record(window, self.token, self.bundle)
        with self.assertRaises(ValueError):
            profile.validate_record(self.record, self.token, self.bundle, sidebar=False)

    def test_refuses_bad_process_fields_and_same_ui_content(self):
        for key, value in (("pid", 0), ("pid", True), ("start", 0), ("start", "456"),
                           ("path", "relative"), ("path", "/tmp/../user/Vane")):
            changed = copy.deepcopy(self.record)
            changed["ui"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                profile.validate_record(changed, self.token, self.bundle)
        changed = copy.deepcopy(self.record)
        changed["content"]["pid"] = 123
        with self.assertRaises(ValueError): profile.validate_record(changed, self.token, self.bundle)

    def test_completed_stage_must_match_the_sampled_owner_and_motion_interval(self):
        finished = dict(self.record, began=100.1, ended=104.0, ownershipHeld=True)
        profile.validate_finished(self.record, finished)
        for changed in (dict(finished, token="b" * 32), dict(finished, began=99.0),
                        dict(finished, ended=100.0), dict(finished, ownershipHeld=False),
                        dict(finished, content=dict(finished["content"], start=999))):
            with self.assertRaises(ValueError): profile.validate_finished(self.record, changed)

    def test_sampler_lifetimes_must_overlap_the_actual_drag(self):
        finished = dict(self.record, began=100.1, ended=104.0, ownershipHeld=True)
        samplers = [{"role": role, "status": 0, "launchedAt": 100.2, "returnedAt": 102.4}
                    for role in ("ui", "content")]
        collection = {"samplers": samplers}
        profile.validate_overlap(collection, finished)
        for changes in ({"launchedAt": 104.1, "returnedAt": 106.4},
                        {"launchedAt": 98.0, "returnedAt": 100.0},
                        {"launchedAt": float("nan")}, {"returnedAt": 99.0}, {"status": 1}):
            changed = copy.deepcopy(collection)
            changed["samplers"][1].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                profile.validate_overlap(changed, finished)
        for changed in (None, {}, {"samplers": samplers[:1]}, {"samplers": [samplers[0], samplers[0]]}):
            with self.assertRaises(ValueError): profile.validate_overlap(changed, finished)

    def test_collection_launches_only_exact_revalidated_targets_and_keeps_the_reports(self):
        commands = []
        class Sampler:
            pid = 222
            def wait(self, timeout): return 0
            def poll(self): return 0
        def launch(command, **kwargs):
            commands.append(command)
            Path(command[-1]).write_text("Call graph:\nowned fixture frame\n")
            return Sampler()
        owners = {entry["pid"]: entry for entry in (self.record["ui"], self.record["content"])}
        with tempfile.TemporaryDirectory() as temp:
            result = profile.collect(self.record, Path(temp), launch, owners.get)
            self.assertEqual([command[:5] for command in commands], [
                ["/usr/bin/sample", "123", "2", "1", "-file"],
                ["/usr/bin/sample", "789", "2", "1", "-file"]])
            self.assertEqual([entry["status"] for entry in result["samplers"]], [0, 0])
            self.assertEqual(json.loads((Path(temp) / "collection.json").read_text()), result)
        commands.clear()
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(ValueError):
            profile.collect(self.record, Path(temp), launch, lambda pid: owners.get(pid) if pid == 123 else None)
        self.assertEqual(commands, [], "A stale content owner must be rejected before launching any sampler")

    def test_collection_discards_a_target_reused_during_sampling(self):
        current = copy.deepcopy(self.record["ui"])
        class Sampler:
            pid = 222
            def wait(self, timeout):
                current["start"] = 1111
                return 0
            def poll(self): return 0
        def launch(command, **kwargs):
            Path(command[-1]).write_text("Call graph:\nowned fixture frame\n")
            return Sampler()
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(ValueError):
            profile.collect(self.record, Path(temp), launch,
                            lambda pid: current if pid == 123 else self.record["content"])


if __name__ == "__main__": unittest.main()
