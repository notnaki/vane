#!/usr/bin/env python3
"""Exercise runtime-only archive transfer and provenance failures."""
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("ci-build-artifact.py")


class BuildArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        spec = importlib.util.spec_from_file_location("artifact", SCRIPT)
        self.artifact = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.artifact)
        self.binary = self.root / ".build/arm64-apple-macosx/debug"
        self.binary.mkdir(parents=True)
        (self.root / ".build/debug").symlink_to("arm64-apple-macosx/debug")
        for relative in ("vane", "VanePackageTests.xctest/Contents/MacOS/VanePackageTests",
                         "Vane_vane.bundle/resource.txt", "vane.build/large.o"):
            p = self.binary / relative
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("fixture")
            p.chmod(0o755)
        (self.binary / "description.json").write_text(json.dumps({"builtTestProducts": [{
            "binaryPath": str(self.binary / "VanePackageTests.xctest/Contents/MacOS/VanePackageTests")}]}))
        app = self.root / "Vane.app/Contents/MacOS/Vane"
        app.parent.mkdir(parents=True)
        app.write_text("fixture")
        app.chmod(0o755)
        self.archive = self.root / "runtime.tar.gz"

    def pack(self):
        self.artifact.pack(self.root, self.binary, self.archive, "revision", "toolchain")

    def test_roundtrip_keeps_only_runtime_resources_modes_and_symlinks(self):
        self.pack()
        with tarfile.open(self.archive) as archive:
            names = archive.getnames()
        self.assertFalse(any("large.o" in name for name in names))
        self.assertIn(".build/arm64-apple-macosx/debug/description.json", names)
        self.assertIn("Vane.app/Contents/MacOS/Vane", names)
        # A consumer has the same checkout path on a different runner.
        (self.root / ".build").rename(self.root / "original-build")
        (self.root / "Vane.app").rename(self.root / "original-app")
        self.artifact.restore(self.root, self.archive, "revision", "toolchain")
        self.assertEqual((self.binary / "Vane_vane.bundle/resource.txt").read_text(), "fixture")
        self.assertTrue((self.root / ".build/debug").is_symlink())
        self.assertTrue((self.binary / "vane").stat().st_mode & 0o111)
        self.assertTrue((self.root / "Vane.app/Contents/MacOS/Vane").stat().st_mode & 0o111)

    def test_mismatched_revision_toolchain_or_checkout_rejects_before_extracting(self):
        self.pack()
        for root, revision, toolchain in ((self.root, "stale", "toolchain"),
                                           (self.root, "revision", "other-sdk"),
                                           (self.root / "other", "revision", "toolchain")):
            with self.subTest(root=root, revision=revision, toolchain=toolchain):
                with self.assertRaises(ValueError):
                    self.artifact.restore(root, self.archive, revision, toolchain)

    def test_missing_tests_or_release_products_cannot_be_published(self):
        with self.assertRaises(ValueError):
            self.artifact.pack(self.root, self.binary.with_name("release"), self.archive, "revision", "toolchain")
        (self.binary / "VanePackageTests.xctest/Contents/MacOS/VanePackageTests").unlink()
        with self.assertRaises(ValueError):
            self.pack()

    def test_unexpected_archive_paths_are_rejected(self):
        self.pack()
        bad = self.root / "unsafe.tar"
        with tarfile.open(self.archive) as original, tarfile.open(bad, "w") as archive:
            for member in original:
                archive.addfile(member, original.extractfile(member) if member.isfile() else None)
            member = tarfile.TarInfo("../escape")
            archive.addfile(member)
        with self.assertRaises((ValueError, tarfile.FilterError)):
            self.artifact.restore(self.root, bad, "revision", "toolchain")
        self.assertFalse((self.root.parent / "escape").exists())


if __name__ == "__main__":
    unittest.main()
