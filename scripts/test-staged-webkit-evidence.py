#!/usr/bin/env python3
"""Pure negative controls for loaded-engine evidence; no native processes."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import uuid

spec = importlib.util.spec_from_file_location("engine", Path(__file__).with_name("check-staged-webkit-evidence.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


def fixture():
    return {"hardenedRuntime": True, "images": [
        {"path": engine.ROOT + f"/{name}.framework/Versions/A/{name}", "uuid": str(uuid.uuid4()), "version": "625.1.29"}
        for name in ("WebKit", "WebCore", "JavaScriptCore")]}


def line(value):
    return "UA ENGINE IMAGES " + json.dumps(value) + "\n"


class EngineEvidenceTests(unittest.TestCase):
    def test_requires_one_hardened_launch_with_all_three_staged_core_images(self):
        value = fixture()
        self.assertEqual(set(engine.validate_image_record(line(value))), {"WebKit", "WebCore", "JavaScriptCore"})
        mutations = []
        for key, replacement in (("hardenedRuntime", False), ("images", value["images"][:-1])):
            changed = copy.deepcopy(value); changed[key] = replacement; mutations.append(changed)
        for key, replacement in (("path", "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"),
                                 ("path", engine.ROOT + "/WebKit"),
                                 ("version", "624.5.1"), ("uuid", "unknown")):
            changed = copy.deepcopy(value); changed["images"][0][key] = replacement; mutations.append(changed)
        changed = copy.deepcopy(value); changed["images"].append(changed["images"][0]); mutations.append(changed)
        for changed in mutations:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                engine.validate_image_record(line(changed))
        for text in ("", line(value) * 2, "UA ENGINE IMAGES {broken\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                engine.validate_image_record(text)


if __name__ == "__main__": unittest.main()
