#!/usr/bin/env python3
"""Load the production emoji catalog from a relocated app, without a build bundle."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, **options):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, **options)
    assert result.returncode == 0, result.stdout[:4000]
    return result.stdout


with tempfile.TemporaryDirectory(prefix="vane-packaged-resources-") as directory:
    temporary = Path(directory)
    build = temporary / "build"
    build.mkdir()
    # Stand in for SwiftPM's generated accessor, which traps when its build resources
    # are unavailable. Packaged production consumers must never initialize it.
    (build / "Accessor.swift").write_text('''import Foundation
extension Bundle {
    static var module: Bundle {
        guard let path = ProcessInfo.processInfo.environment["VANE_TEST_FALLBACK_BUNDLE"],
              let bundle = Bundle(path: path) else {
            fatalError("SwiftPM build resource bundle is unavailable")
        }
        return bundle
    }
}
''')
    (build / "main.swift").write_text('''import Foundation
let entries = SpaceEmojiCatalog.entries
precondition(entries.count > 3000, "The installed emoji catalog must load")
precondition(Set(entries.map(\\.category)) == Set(SpaceEmojiCatalog.Category.allCases))
precondition(SpaceEmojiCatalog.search("robot", category: .nature).contains { $0.emoji == "🤖" })
precondition(SpaceEmojiCatalog.search("flag turkey", category: .people).contains { $0.emoji == "🇹🇷" })
let food = SpaceEmojiCatalog.search("", category: .food)
precondition(!food.isEmpty && food.allSatisfy { $0.category == .food })
print("PASS: production emoji catalog loads and searches")
''')
    executable = build / "ResourceCheck"
    run(["swiftc", str(ROOT / "Sources/Vane/AppResources.swift"),
         str(ROOT / "Sources/Vane/SpaceEmojiCatalog.swift"), str(build / "Accessor.swift"),
         str(build / "main.swift"), "-o", str(executable)])
    env = {key: value for key, value in os.environ.items() if key != "VANE_TEST_FALLBACK_BUNDLE"}
    resource_source = ROOT / "Sources/Vane/SpaceEmoji"
    fallback = build / "Vane_vane.bundle"
    fallback.mkdir()
    shutil.copytree(resource_source, fallback / "SpaceEmoji")
    run([str(executable)], env={**env, "VANE_TEST_FALLBACK_BUNDLE": str(fallback)})

    app = temporary / "Applications/ResourceCheck.app"
    binaries = app / "Contents/MacOS"
    binaries.mkdir(parents=True)
    resources = app / "Contents/Resources/Vane_vane.bundle"
    resources.parent.mkdir()
    shutil.copytree(fallback, resources)
    with (app / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "test.vane.resource-check",
                      "CFBundlePackageType": "APPL", "CFBundleExecutable": "ResourceCheck"}, info)
    installed = binaries / "ResourceCheck"
    shutil.move(executable, installed)
    shutil.rmtree(build)
    assert not build.exists()
    print(run([str(installed)], env=env).strip())

# The generated accessor is allowed only behind AppResources' lazy fallback.
violations = [str(source.relative_to(ROOT)) for source in (ROOT / "Sources").rglob("*.swift")
              if source != ROOT / "Sources/Vane/AppResources.swift" and "Bundle.module" in source.read_text()]
assert not violations, f"Use AppResources for packaged resources: {violations}"
print("PASS: relocated app and command-line fallback; resource accessor policy")
