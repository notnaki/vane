#!/usr/bin/env python3
"""Check the real app packager's default-browser policy without signing identities."""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def executable(path, body):
    path.write_text("#!/bin/bash\nset -eu\n" + body)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix="vane-default-browser-") as directory:
    fixture = Path(directory)
    shutil.copy2(ROOT / "make-app.sh", fixture / "make-app.sh")
    (fixture / "installer").mkdir()
    shutil.copy2(ROOT / "installer/UpdateInstaller-Info.plist", fixture / "installer")
    shutil.copy2(ROOT / "installer/IconService-Info.plist", fixture / "installer")
    shutil.copy2(ROOT / "Vane.entitlements", fixture)
    for configuration in ("debug", "release"):
        binary = fixture / ".build" / configuration / "vane"
        binary.parent.mkdir(parents=True)
        executable(binary, "exit 0\n")
        fonts = binary.parent / "Vane_vane.bundle/Contents/Resources/EaselFonts"
        shutil.copytree(ROOT / "Sources/Vane/EaselFonts", fonts)

    # Replace only toolchain/signing boundaries; the real shell script emits the plist.
    commands = fixture / "commands"
    commands.mkdir()
    executable(commands / "swift", "exit 0\n")
    executable(commands / "xcrun", """
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    printf '#!/bin/bash\\nexit 0\\n' > "$1"
    chmod +x "$1"
  fi
  shift
done
""")
    executable(commands / "codesign", """
if [ "$1" = -d ] && [ "${@: -1}" = Vane.app ]; then
  echo 'com.apple.security.app-sandbox temporary-exception.files.absolute-path.read-write'
fi
""")
    cases = [
        ("debug", "", "1.2.3", False),
        ("release", "", "1.2.3", False),
        ("release", "-", "1.2.3", False),
        ("debug", "Developer ID Application: Fixture", "1.2.3", False),
        ("release", "Developer ID Application: Fixture", "1.2.3-rc1", False),
        ("release", "Developer ID Application: Fixture", "1.2.3", True),
    ]
    for configuration, identity, version, expected in cases:
        environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                       "TMPDIR": str(fixture), "SIGN_ID": identity,
                       "VANE_VERSION": version, "VANE_BUILD": "1"}
        subprocess.run(["bash", str(fixture / "make-app.sh"), configuration],
                       env=environment, check=True, capture_output=True, text=True)
        with (fixture / "Vane.app/Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        actual = info.get("VaneDefaultBrowserPromptEnabled")
        assert actual is expected, (configuration, identity, version, expected, actual)
        bundled = fixture / "Vane.app/Contents/Resources/Vane_vane.bundle/Contents/Resources/EaselFonts"
        for font in ("Excalifont-Regular.ttf", "Nunito-Regular.ttf", "ComicShanns-Regular.ttf"):
            assert (bundled / font).read_bytes() == (ROOT / "Sources/Vane/EaselFonts" / font).read_bytes()

print("PASS: local, debug, ad-hoc, and prerelease bundles suppress the default-browser prompt")
