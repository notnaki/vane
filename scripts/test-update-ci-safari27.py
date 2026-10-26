#!/usr/bin/env python3
"""Pure guards for selecting one Apple Safari update on disposable CI."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("safari_update", Path(__file__).with_name("update-ci-safari27.py"))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class SafariUpdateTests(unittest.TestCase):
    def test_selects_latest_stable_safari27_for_tahoe_without_selecting_os_updates(self):
        catalog = """
Software Update found the following new or updated software:
* Label: macOS Golden Gate 27.0.1-26A434
  Title: macOS Golden Gate, Version: 27.0.1, Action: restart,
* Label: Safari27.0TahoeAuto-27.0
  Title: Safari, Version: 27.0,
* Label: Safari27.0.1TahoeAuto-27.0.1
  Title: Safari, Version: 27.0.1,
* Label: Safari27.2TahoeBeta-27.2
  Title: Safari Beta, Version: 27.2,
* Label: Safari27.1SequoiaAuto-27.1
  Title: Safari, Version: 27.1,
"""
        self.assertEqual(update.select_safari_update(catalog), "Safari27.0.1TahoeAuto-27.0.1")

    def test_missing_malformed_and_ambiguous_updates_fail_closed(self):
        samples = ["", "* Label: macOS Tahoe 26.7-25H1", "* Label: Safari26.6TahoeAuto-26.6",
                   "* Label: Safari27.1TahoeAuto-27.0", "* Label: Safari27.0TahoeAuto-27.0; reboot",
                   "* Label: Safari28.0TahoeAuto-28.0",
                   "* Label: Safari27.0TahoeAuto-27.0\n* Label: Safari27.0TahoeAuto-27.0"]
        for sample in samples:
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                update.select_safari_update(sample)

    def test_only_disposable_hosted_macos26_can_install(self):
        allowed = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}
        update.require_hosted_macos26(allowed, "26.6.2")
        for key in allowed:
            with self.subTest(key=key), self.assertRaises(ValueError):
                update.require_hosted_macos26({**allowed, key: ""}, "26.6.2")
        for version in ("15.8", "27.0.1", "", "26invalid"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                update.require_hosted_macos26(allowed, version)

    def test_disk_postcondition_requires_both_safari27_and_newer_system_webkit(self):
        update.require_updated_engine("27.0.1", "21625.1.29.11.28")
        for safari, webkit in (("27.0.1", "21624.5.1.11.3"), ("26.6.2", "21625.1.29.11.28"),
                               ("27.0.1", "unknown"), ("28.0", "21625.1.29.11.28"),
                               ("27.0.1", "22625.1.29.11.28")):
            with self.subTest(safari=safari, webkit=webkit), self.assertRaises(ValueError):
                update.require_updated_engine(safari, webkit)


if __name__ == "__main__": unittest.main()
