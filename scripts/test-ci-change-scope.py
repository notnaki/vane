#!/usr/bin/env python3
"""Exercise cheap-check scope against real Git diffs, including renames."""
from pathlib import Path
import os
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

    def scope(self, expected, base=None, env=None):
        result = subprocess.run([sys.executable, str(SCRIPT), "--base", self.base if base is None else base,
                                 "--head", "HEAD"], cwd=self.root, capture_output=True, text=True,
                                env={**os.environ, **(env or {})})
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

    def test_root_gitignore_add_edit_and_delete_skip_app_work(self):
        ignore = self.root / ".gitignore"
        for content in ("cache/\n", "cache/\nlocal/\n", None):
            with self.subTest(content=content):
                base = self.git("rev-parse", "HEAD")
                if content is None:
                    ignore.unlink()
                else:
                    ignore.write_text(content)
                self.commit()
                self.scope(False, base)

    def test_root_gitignore_with_documentation_skips_app_work(self):
        (self.root / ".gitignore").write_text("cache/\n")
        (self.root / "README.md").write_text("Updated\n")
        self.commit()
        self.scope(False)

    def test_root_gitignore_with_source_requires_app_work(self):
        (self.root / ".gitignore").write_text("cache/\n")
        (self.root / "App.swift").write_text("changed\n")
        self.commit()
        self.scope(True)

    def test_nested_gitignore_requires_app_work(self):
        (self.root / "Sources").mkdir()
        (self.root / "Sources/.gitignore").write_text("cache/\n")
        self.commit()
        self.scope(True)

    def test_workflows_scripts_resources_and_unknown_paths_require_app_work(self):
        for name in (".github/workflows/checks.yml", "scripts/check.py", "Sources/Welcome.md", "docs/probe.swift", "docs/unknown.bin"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
                self.commit()
                self.scope(True)

    def test_website_assets_and_routing_tools_skip_app_work(self):
        for name in ("docs/index.html", "docs/styles.css", "docs/space.js", "docs/tests/galaxy.test.cjs",
                     "docs/media/logo.svg", "docs/media/screenshot.png", "docs/.nojekyll",
                     "scripts/ci-change-scope.py", "scripts/test-ci-change-scope.py",
                     "scripts/test-checks-workflow.py"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
                base = self.git("rev-parse", "HEAD")
                self.commit()
                self.scope(False, base)

    def test_website_mixed_with_source_requires_app_work(self):
        (self.root / "docs").mkdir()
        (self.root / "docs/styles.css").write_text("body {}\n")
        (self.root / "App.swift").write_text("changed\n")
        self.commit()
        self.scope(True)

    def test_pr_merge_compares_actual_target_parent_when_event_base_is_stale(self):
        (self.root / "docs").mkdir()
        (self.root / "docs/index.html").write_text("Website\n")
        feature = self.commit()
        self.git("checkout", "-qb", "target", self.base)
        (self.root / "App.swift").write_text("New target source\n")
        self.commit()
        self.git("merge", "--no-ff", feature, "-m", "PR integration")
        merge = self.git("rev-parse", "HEAD")
        context = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_SHA": merge,
                   "PR_HEAD_SHA": feature}
        self.scope(False, env=context)
        self.scope(True, env={**context, "PR_HEAD_SHA": self.base})
        self.scope(True, env={**context, "GITHUB_SHA": feature})
        self.scope(True, env={**context, "GITHUB_EVENT_NAME": "push"})

    def test_pr_source_changes_still_require_app_checks_against_actual_target(self):
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Feature.swift").write_text("New feature\n")
        feature = self.commit()
        self.git("checkout", "-qb", "target", self.base)
        (self.root / "README.md").write_text("Target docs\n")
        self.commit()
        self.git("merge", "--no-ff", feature, "-m", "PR integration")
        self.scope(True, env={"GITHUB_EVENT_NAME": "pull_request",
                             "GITHUB_SHA": self.git("rev-parse", "HEAD"),
                             "PR_HEAD_SHA": feature})

    def test_website_video_fonts_and_licenses_skip_app_work(self):
        for name in ("docs/media/session.webm", "docs/media/session.mp4",
                     "docs/fonts/wordmark.ttf", "docs/fonts/OFL.txt",
                     "docs/fonts/Pinyon-OFL.txt"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"website asset\n")
                base = self.git("rev-parse", "HEAD")
                self.commit()
                self.scope(False, base)

    def test_named_search_indexing_files_skip_app_work(self):
        for name in ("docs/robots.txt", "docs/sitemap.xml", "docs/CNAME", "scripts/check-site-rendering.swift",
                     "docs/versions/galaxy-v2/VERSION.txt", "docs/versions/liquid-v3/VERSION.txt"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("website indexing\n")
                base = self.git("rev-parse", "HEAD")
                self.commit()
                self.scope(False, base)

    def test_unknown_text_and_xml_still_require_app_work(self):
        for name in ("docs/unknown.txt", "docs/unknown.xml", "Resources/sitemap.xml"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
                base = self.git("rev-parse", "HEAD")
                self.commit()
                self.scope(True, base)

    def test_website_media_does_not_exempt_unknown_files_or_source(self):
        for name in ("docs/fonts/instructions.txt", "docs/fonts/setup.py",
                     "Sources/session.mp4", "Resources/wordmark.ttf"):
            with self.subTest(name=name):
                p = self.root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
                base = self.git("rev-parse", "HEAD")
                self.commit()
                self.scope(True, base)

    def test_workflow_routing_edits_skip_but_native_edits_require_app_work(self):
        workflow = self.root / ".github/workflows/checks.yml"
        workflow.parent.mkdir(parents=True)
        original = Path(__file__).resolve().parents[1].joinpath(".github/workflows/checks.yml").read_text()
        workflow.write_text(original)
        self.base = self.commit()
        workflow.write_text(original.replace("name: Change scope and diff checks", "name: Fast routing checks"))
        self.commit()
        self.scope(False)
        workflow.write_text(original.replace("python3 scripts/test-ci-change-scope.py",
                                             "python3 -B scripts/test-ci-change-scope.py"))
        self.commit()
        self.scope(False)
        for changed in (
            original.replace("-c debug --build-tests", "-c release --build-tests"),
            original.replace("timeout-minutes: 24", "timeout-minutes: 25"),
            original.replace("contents: read", "contents: write", 1),
            original + "\n  extra:\n    runs-on: ubuntu-latest\n",
        ):
            with self.subTest(changed=changed[-80:]):
                workflow.write_text(changed)
                self.commit()
                self.scope(True)

    def test_workflow_added_or_deleted_requires_app_work(self):
        workflow = self.root / ".github/workflows/checks.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text("jobs:\n  build:\n    runs-on: macos-26\n")
        self.commit()
        self.scope(True)
        self.base = self.git("rev-parse", "HEAD")
        workflow.unlink()
        self.commit()
        self.scope(True)

    def test_renaming_app_source_to_website_keeps_app_checks(self):
        (self.root / "docs").mkdir()
        self.git("mv", "App.swift", "docs/app.js")
        self.commit()
        self.scope(True)

    def test_renaming_source_to_documentation_keeps_app_checks(self):
        self.git("mv", "App.swift", "guide.md")
        self.commit()
        self.scope(True)

    def test_renaming_source_to_root_gitignore_keeps_app_checks(self):
        self.git("mv", "App.swift", ".gitignore")
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

    def test_cheap_path_whitespace_failure_fails_the_scope_job(self):
        for name in ("README.md", ".gitignore"):
            with self.subTest(name=name):
                base = self.git("rev-parse", "HEAD")
                (self.root / name).write_text("bad whitespace \n")
                self.commit()
                result = subprocess.run([sys.executable, str(SCRIPT), "--base", base, "--head", "HEAD"],
                                        cwd=self.root, capture_output=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
