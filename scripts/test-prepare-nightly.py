#!/usr/bin/env python3
"""Exercise nightly release eligibility and versioning without network or credentials."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name("prepare-nightly.py")


class NightlyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not path.exists():
            raise AssertionError("Nightly release preparation has not been implemented")
        spec = importlib.util.spec_from_file_location("nightly", path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def prepare(self, **changes):
        options = dict(sha="abc", ref="refs/heads/main", run_id="100", date="20261031",
                       runs=[dict(id=5, head_sha="abc", head_branch="main", event="push",
                                  status="completed", conclusion="success")],
                       releases=[], tags=["v1.2.3", "v9.0.0-rc.1"], markers={},
                       tag_commit=lambda tag: "old")
        options.update(changes)
        return self.module.prepare(**options)

    def test_changed_checked_main_uses_next_patch(self):
        self.assertEqual(self.prepare(), "v1.2.4-nightly.20261031.100")

    def test_non_main_rejected_even_when_checks_pass(self):
        with self.assertRaisesRegex(ValueError, "main"):
            self.prepare(ref="refs/heads/feature")

    def test_missing_failed_pending_or_wrong_revision_checks_skip(self):
        for runs in [[], [dict(id=5, head_sha="other", head_branch="main", event="push", status="completed", conclusion="success")],
                     [dict(id=5, head_sha="abc", head_branch="main", event="pull_request", status="completed", conclusion="success")],
                     [dict(id=5, head_sha="abc", head_branch="main", event="push", status="in_progress", conclusion=None)],
                     [dict(id=5, head_sha="abc", head_branch="main", event="push", status="completed", conclusion="failure")]]:
            with self.subTest(runs=runs):
                self.assertIsNone(self.prepare(runs=runs))

    def test_newer_failed_run_does_not_hide_behind_older_success(self):
        passing = dict(id=5, head_sha="abc", head_branch="main", event="push", status="completed", conclusion="success")
        failing = {**passing, "id": 6, "conclusion": "failure"}
        self.assertIsNone(self.prepare(runs=[passing, failing]))

    def test_unchanged_published_nightly_skips_but_drafts_do_not(self):
        release = dict(tag_name="v1.2.4-nightly.20261030.90", draft=False, prerelease=True)
        self.assertIsNone(self.prepare(releases=[release], tag_commit=lambda tag: "abc"))
        self.assertIsNotNone(self.prepare(releases=[{**release, "draft": True}], tag_commit=lambda tag: "abc"))

    def test_nightly_and_rc_tags_do_not_bump_stable_core(self):
        self.assertEqual(self.prepare(tags=["v1.9.9", "v1.10.0", "v9.0.0-nightly.20261031.99", "v8.0.0-rc.1"]),
                         "v1.10.1-nightly.20261031.100")

    def test_publication_retry_reuses_original_tag(self):
        tag = "v1.2.4-nightly.20261030.100"
        self.assertEqual(self.prepare(markers={tag: "vane-release-run:100"}, tag_commit=lambda tag: "abc"), tag)
        with self.assertRaisesRegex(ValueError, "different commit"):
            self.prepare(markers={tag: "vane-release-run:100"})

    def test_existing_tag_from_other_run_cannot_be_overwritten(self):
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.prepare(tags=["v1.2.3", "v1.2.4-nightly.20261031.100"])

    def test_missing_stable_tag_starts_at_first_patch(self):
        self.assertEqual(self.prepare(tags=[]), "v0.0.1-nightly.20261031.100")


if __name__ == "__main__":
    unittest.main()
