#!/usr/bin/env python3
"""Exercise documentation scope against real Git diffs, including renames."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("ci-change-scope.py")


class ChangeScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@invalid")
        (self.root / "README.md").write_text("Initial\n")
        (self.root / "App.swift").write_text("initial source\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def scope(self, expected, base=None):
        result = subprocess.run([sys.executable, str(SCRIPT), "--base", self.base if base is None else base,
                                 "--head", "HEAD"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_required=" + str(expected).lower(), result.stdout)

    def test_root_and_docs_markdown_skip_app_work(self):
        (self.root / "SECURITY.md").write_text("Report privately\n")
        (self.root / "docs").mkdir()
        (self.root / "docs/guide.md").write_text("Guide\n")
        self.commit()
        self.scope(False)

    def test_source_mixed_with_documentation_requires_app_work(self):
        (self.root / "README.md").write_text("Updated\n")
        (self.root / "App.swift").write_text("changed\n")
        self.commit()
        self.scope(True)

    def test_workflows_scripts_resources_and_unknown_paths_require_app_work(self):
        for name in (".github/workflows/checks.yml", "scripts/check.py", "Sources/Welcome.md", "docs/index.html"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
                self.commit()
                self.scope(True)

    def test_renaming_source_to_documentation_keeps_app_checks(self):
        self.git("mv", "App.swift", "guide.md")
        self.commit()
        self.scope(True)

    def test_deleted_documentation_is_docs_only(self):
        (self.root / "README.md").unlink()
        self.commit()
        self.scope(False)

    def test_missing_zero_or_empty_history_fails_closed_to_app_checks(self):
        for base in ("0" * 40, "missing-ref", "", self.base):
            with self.subTest(base=base):
                self.scope(True, base)

    def test_documentation_whitespace_failure_fails_the_scope_job(self):
        (self.root / "README.md").write_text("bad whitespace \n")
        self.commit()
        result = subprocess.run([sys.executable, str(SCRIPT), "--base", self.base, "--head", "HEAD"],
                                cwd=self.root, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
