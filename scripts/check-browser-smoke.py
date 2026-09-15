#!/usr/bin/env python3
"""Run real WebKit smoke checks in an isolated signed sandbox bundle.

Requires macOS 26 and a logged-in graphical session. This verifies sandbox behavior,
not installation. By default it creates an ad-hoc fixture from a built Vane executable.
Use --app to test an existing bundle unchanged, and --distribution to require the
Developer ID, notarization, and Gatekeeper checks used for a release candidate.
"""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

TEAM_ID = "T7X84HN3W3"


def run_checked(command, description):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if result.stdout:
        print(result.stdout.rstrip(), flush=True)
    if result.returncode:
        print(f"FAIL: {description}", file=sys.stderr)
        raise SystemExit(1)
    return result.stdout


def verify_distribution(app):
    run_checked(["codesign", "--verify", "--deep", "--strict", str(app)],
                "release app has an invalid code signature")
    signing = run_checked(["codesign", "-dvv", str(app)],
                          "release app signing information is unavailable")
    team = next((line.partition("=")[2] for line in signing.splitlines()
                 if line.startswith("TeamIdentifier=")), "")
    if team != TEAM_ID:
        print(f"FAIL: release app TeamIdentifier is {team or 'missing'}, expected {TEAM_ID}",
              file=sys.stderr)
        raise SystemExit(1)
    run_checked(["xcrun", "stapler", "validate", str(app)],
                "release app has no valid stapled notarization ticket")
    run_checked(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
                "Gatekeeper rejected the release app")
    print(f"Verified Developer ID distribution bundle (team {TEAM_ID}).", flush=True)


def executable_in(app, parser):
    info_path = app / "Contents/Info.plist"
    if not app.is_dir() or not info_path.is_file():
        parser.error("--app must name an application bundle containing Contents/Info.plist")
    try:
        executable_name = plistlib.loads(info_path.read_bytes())["CFBundleExecutable"]
    except (OSError, plistlib.InvalidFileException, KeyError, TypeError):
        parser.error("--app Info.plist must contain a valid CFBundleExecutable")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--app CFBundleExecutable must name an executable file")
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--binary", type=Path,
                        help="built executable to place in a temporary ad-hoc fixture")
    source.add_argument("--app", type=Path,
                        help="existing signed app bundle to execute without changing it")
    parser.add_argument("--distribution", action="store_true",
                        help="require Developer ID, notarization, and Gatekeeper checks")
    options = parser.parse_args()
    if options.distribution and options.app is None:
        parser.error("--distribution requires --app")
    if sys.platform != "darwin":
        parser.error("requires macOS")
    downloads = Path.home() / "Downloads"
    if not downloads.is_dir():
        parser.error("~/Downloads must exist for the sandbox-isolated test directory")

    binary = (options.binary or root / ".build/debug/vane").resolve()
    app = options.app.resolve() if options.app else None
    if app:
        executable = executable_in(app, parser)
        if options.distribution:
            verify_distribution(app)
        bundle_context = None
        message = "Running supplied signed app bundle unchanged."
    else:
        if not binary.is_file():
            parser.error("requires a built Vane executable (--binary)")
        bundle_context = tempfile.TemporaryDirectory(prefix="vane-browser-smoke-")
        app = Path(bundle_context.name) / "Vane Browser Check.app"
        executable = app / "Contents/MacOS/vane"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        info = {
            "CFBundleIdentifier": "io.github.notnaki.vane.browsercheck." + uuid.uuid4().hex,
            "CFBundleExecutable": "vane",
            "CFBundleName": "Vane Browser Check",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "0.1",
            "NSPrincipalClass": "NSApplication",
            "LSMinimumSystemVersion": "26.0",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run([
            "codesign", "--force", "--sign", "-", "--entitlements",
            str(root / "Vane.entitlements"), str(app),
        ], check=True)
        message = "Running ad-hoc signed sandbox fixture."

    # The production Downloads entitlement admits this directory without adding a
    # sandbox exception. The environment is deliberately allowlisted so CI secrets are
    # never inherited by the app under test.
    with tempfile.TemporaryDirectory(prefix=".vane-browser-smoke-", dir=downloads) as data:
        environment = {name: os.environ[name] for name in
                       ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG")
                       if name in os.environ}
        environment["VANE_DATA_DIR"] = data
        print(message + " Requires a graphical session.", flush=True)
        try:
            result = subprocess.run([str(executable), "browsercheck"], env=environment, timeout=75)
        except subprocess.TimeoutExpired:
            print("FAIL: browser smoke process exceeded 75 seconds", file=sys.stderr)
            return 1
        finally:
            if bundle_context is not None:
                bundle_context.cleanup()
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
