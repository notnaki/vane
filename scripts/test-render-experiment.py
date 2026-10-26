#!/usr/bin/env python3
"""Keep A/B launch flags and synthetic-data isolation intact."""
import importlib.util
from pathlib import Path
import unittest
import tempfile
import json

spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("ui-responsiveness-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class RenderExperimentLaunchTests(unittest.TestCase):
    def test_optimized_flags_reach_child(self):
        source = {key: "1" for key in fixture.RENDER_FLAGS}
        source["VANE_DIAG_SCROLL_TRACE"] = "1"
        child = fixture.launch_environment(Path("/tmp/synthetic"), source)
        for key, value in source.items():
            self.assertEqual(child[key], value)

    def test_baseline_and_independent_opt_outs_are_preserved(self):
        source = dict(zip(fixture.RENDER_FLAGS, ("0", "1", "0", "0")))
        child = fixture.launch_environment(Path("/tmp/synthetic"), source)
        for key, value in source.items():
            self.assertEqual(child[key], value)

    def test_no_flags_are_invented_for_existing_callers(self):
        child = fixture.launch_environment(Path("/tmp/synthetic"), {"PATH": "/usr/bin"})
        self.assertFalse(any(key in child for key in fixture.RENDER_FLAGS))
        self.assertEqual(child["PATH"], "/usr/bin")

    def test_parent_data_directory_and_secrets_are_never_inherited(self):
        child = fixture.launch_environment(Path("/tmp/synthetic"), {
            "VANE_DATA_DIR": "/private/real-profile", "API_KEY": "do-not-forward",
            "VANE_UNKNOWN_FLAG": "do-not-forward", "HOME": "/home/example"})
        self.assertEqual(child, {"VANE_DATA_DIR": "/tmp/synthetic", "HOME": "/home/example"})

    def test_real_websites_are_preserved_in_browser_rows_and_favourites(self):
        urls = ["https://example.com/a?query=preserve#fragment", "https://example.org/b"]
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary) / "data"
            fixture.seed(data, 8123, True, urls)
            session = json.loads((data / "session.json").read_text())
            spaces = json.loads((data / "spaces.json").read_text())
            self.assertEqual({row["url"] for window in session["windows"] for row in window}, set(urls))
            self.assertTrue(all(url in urls for space in spaces for url in space["pinnedURLs"]))

    def test_existing_local_page_fixture_is_unchanged_without_websites(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary) / "data"
            fixture.seed(data, 8123, False)
            session = json.loads((data / "session.json").read_text())
            self.assertTrue(all(row["url"].startswith("http://127.0.0.1:8123/page.html?")
                                for window in session["windows"] for row in window))


if __name__ == "__main__":
    unittest.main()
