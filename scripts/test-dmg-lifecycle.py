#!/usr/bin/env python3
"""Exercise the real DMG builder with isolated disk/Finder command boundaries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

# No disk images, mounts, Finder windows, or signed applications are created.
COMMAND = r'''
import json, os, pathlib, plistlib, sys
state_path = pathlib.Path(os.environ["DMG_MOCK_STATE"])
state = json.loads(state_path.read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
state["calls"].append([name, *args])
def finish(code=0, output=None):
    state_path.write_text(json.dumps(state))
    if output is not None:
        sys.stdout.buffer.write(plistlib.dumps(output))
    sys.exit(code)
if name == "hdiutil":
    verb = args[0]
    if verb == "create":
        if state["scenario"] == "create-error":
            finish(16)
        pathlib.Path(args[-1]).touch()
    elif verb == "attach":
        state["image"] = args[1]
        state["attached"] = True
        state["mount"] = str(state_path.parent / "mounted")
        pathlib.Path(state["mount"]).mkdir(exist_ok=True)
        finish(code=5 if state["scenario"] == "partial-attach" else 0, output={"system-entities": [
            {"dev-entry": "/dev/disk987", "content-hint": "GUID_partition_scheme", "potentially-mountable": False},
            {"dev-entry": "/dev/disk987s1", "content-hint": "Apple_HFS", "potentially-mountable": True,
             "mount-point": state["mount"], "volume-kind": "hfs"}]})
    elif verb == "info":
        image = state.get("image", "")
        device = "/dev/disk987"
        reused = (state["scenario"] == "reused-device" or
                  state["scenario"] == "reused-after-busy" and state.get("detaches", 0) > 0 or
                  state["scenario"] == "reused-before-force" and state.get("detaches", 0) >= 10)
        if state.get("layout_done") and reused:
            image = "/Users/someone/unrelated.dmg"
        if state["scenario"] == "invalid-info":
            sys.stdout.write("not a plist")
            finish()
        if "-plist" in args:
            finish(output={"images": ([{"image-path": image,
                "system-entities": [{"dev-entry": device},
                                    {"dev-entry": device + "s1", "mount-point": state["mount"]}]}]
                if state.get("attached") else [])})
        if state.get("attached"):
            print(device + " " + image)
    elif verb == "detach":
        if state.get("layout_done") and (state["scenario"] == "reused-device" or
                state["scenario"] == "reused-after-busy" and state.get("detaches", 0) > 0 or
                state["scenario"] == "reused-before-force" and state.get("detaches", 0) >= 10):
            state["unrelated_detached"] = True
        count = state.get("detaches", 0)
        state["detaches"] = count + 1
        busy = state["scenario"] in ("always-busy", "reused-after-busy", "reused-before-force") or (state["scenario"] == "busy-once" and count == 0)
        if busy and "-force" not in args:
            print("fixture detach: Resource busy", file=sys.stderr)
            finish(16)
        if state["scenario"] == "detach-error" and "-force" not in args:
            print("fixture detach: Input/output error", file=sys.stderr)
            finish(5)
        state["attached"] = False
    elif verb == "convert":
        if state.get("attached"):
            finish(99)
        pathlib.Path(args[args.index("-o") + 1]).touch()
elif name == "osascript":
    if "-e" in args:
        print("true")
    else:
        sys.stdin.read()
        state["layout_done"] = True
elif name == "ditto":
    import shutil
    shutil.copytree(args[0], args[1])
finish()
'''


class LifecycleTests(unittest.TestCase):
    def build(self, scenario):
        temporary = tempfile.TemporaryDirectory(prefix="vane-dmg-mock-")
        self.addCleanup(temporary.cleanup)
        fixture = Path(temporary.name)
        commands = fixture / "commands"
        commands.mkdir()
        for name in ("hdiutil", "osascript", "codesign", "sips", "tiffutil", "ditto", "diskutil", "sync", "sleep"):
            command = commands / name
            command.write_text(f"#!{sys.executable}\n" + COMMAND)
            command.chmod(0o755)
        state = fixture / "state.json"
        state.write_text(json.dumps({"scenario": scenario, "calls": []}))
        app = fixture / "Vane.app"
        app.mkdir()
        output = fixture / "Vane.dmg"
        result = subprocess.run(["bash", str(ROOT / "scripts/build-dmg.sh"), str(app), str(output)],
            env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                 "TMPDIR": str(fixture), "DMG_MOCK_STATE": str(state)},
            capture_output=True, text=True, timeout=15)
        return result, json.loads(state.read_text()), output

    def test_busy_owned_detach_finishes_before_conversion(self):
        result, state, output = self.build("busy-once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.exists())
        self.assertFalse(state["attached"])
        self.assertFalse(any("-force" in call for call in state["calls"]))

    def test_persistent_busy_preserves_failure_and_never_converts(self):
        result, state, output = self.build("always-busy")
        self.assertEqual(result.returncode, 16, result.stderr)
        self.assertFalse(output.exists())
        self.assertIn("detach", result.stderr)
        self.assertIn("Resource busy", result.stderr)
        self.assertFalse(state["attached"], "cleanup must retire the verified owned image")

    def test_reused_device_is_never_detached(self):
        result, state, output = self.build("reused-device")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state.get("unrelated_detached", False), "never detach another image on a reused device")
        self.assertFalse(output.exists())

    def test_create_error_identifies_failed_stage_and_preserves_status(self):
        result, state, output = self.build("create-error")
        self.assertEqual(result.returncode, 16)
        self.assertIn("create", result.stderr)
        self.assertFalse(output.exists())

    def test_nonbusy_detach_error_is_not_retried_in_build(self):
        result, state, output = self.build("detach-error")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(output.exists())
        self.assertIn("Input/output error", result.stderr)
        self.assertEqual(state["detaches"], 2, "one build attempt and one cleanup attempt")
        self.assertFalse(any("-force" in call for call in state["calls"]))

    def test_device_identity_is_rechecked_before_busy_retry(self):
        result, state, output = self.build("reused-after-busy")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["detaches"], 1)
        self.assertFalse(state.get("unrelated_detached", False))
        self.assertFalse(output.exists())

    def test_force_cleanup_rechecks_identity_and_preserves_build_status(self):
        result, state, output = self.build("reused-before-force")
        self.assertEqual(result.returncode, 16, result.stderr)
        self.assertFalse(any("-force" in call for call in state["calls"]))
        self.assertFalse(state.get("unrelated_detached", False))
        self.assertTrue(Path(state["image"]).exists(), "preserve unresolved attached image")
        self.assertFalse(output.exists())

    def test_unreadable_ownership_never_detaches_or_deletes_image(self):
        result, state, output = self.build("invalid-info")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("detaches", state)
        self.assertTrue(Path(state["image"]).exists())
        self.assertFalse(output.exists())

    def test_partial_attach_failure_cleans_exact_owned_image(self):
        result, state, output = self.build("partial-attach")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(state["attached"], "a failed attach can still leave an owned mounted image")
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
