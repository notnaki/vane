#!/usr/bin/env python3
"""Run real WebKit smoke checks in an isolated signed sandbox bundle.

Requires macOS 26 and a logged-in graphical session. This verifies sandbox behavior,
not installation. By default it creates an ad-hoc fixture from a built Vane executable.
Use --app to test an existing bundle unchanged, and --distribution to require the
Developer ID, notarization, and Gatekeeper checks used for a release candidate.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import signal
from datetime import datetime
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



def run_fixture(command, environment, app, timeout):
    with subprocess.Popen(command, env=environment) as process:
        started = subprocess.check_output(
            ["ps", "-p", str(process.pid), "-o", "lstart="], text=True).strip()
        print(f"TEST PROCESS bundle={app} pid={process.pid} start={started} launched={datetime.now().isoformat()}", flush=True)
        stopped = threading.Event()
        injection_errors = []

        def terminate_content():
            request = Path(environment["VANE_DATA_DIR"]) / "terminate-webcontent.json"
            seen = set()
            while not stopped.wait(0.05) and process.poll() is None:
                if not request.exists():
                    continue
                try:
                    event = json.loads(request.read_text())
                    if event["token"] in seen:
                        continue
                    seen.add(event["token"])
                    pid = int(event["pid"])
                    identity = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart=,comm="], text=True).strip()
                    if pid <= 0 or "com.apple.WebKit.WebContent" not in identity:
                        raise RuntimeError("reported process is not a live WebKit content service")
                    print(f"TEST WEBKIT pid={pid} identity={identity}", flush=True)
                    current = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart=,comm="], text=True).strip()
                    if current != identity:
                        raise RuntimeError("WebKit process identity changed before signal")
                    os.kill(pid, signal.SIGKILL)
                except Exception as error:
                    injection_errors.append(str(error))
                    print(f"FAIL WebKit termination injection: {error}", flush=True)
                    return

        injector = None
        if "--crash-recovery" in command:
            injector = threading.Thread(target=terminate_content, daemon=True)
            injector.start()

        def stop_owned(sig):
            if process.poll() is not None:
                return
            identity = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "lstart=,comm="], text=True).strip()
            if started not in identity or str(Path(command[0]).resolve()) not in identity:
                raise RuntimeError("owned app process identity changed before cleanup")
            process.send_signal(sig)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The unreaped child PID cannot be reused; target only this owned process.
            stop_owned(signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop_owned(signal.SIGKILL)
                process.wait()
            print(f"TEST PROCESS terminated pid={process.pid}", flush=True)
            raise
        finally:
            stopped.set()
            if injector:
                injector.join(timeout=5)
        print(f"TEST PROCESS exited pid={process.pid} code={code}", flush=True)
        return code or bool(injection_errors)


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
    parser.add_argument("--lifecycle", action="store_true", help="100 tab/window cycles, 200 parked rows, settling and idle CPU")
    parser.add_argument("--public-media", action="store_true", help="opt-in sustained Shaka public-demo playback (network required, no accounts)")
    parser.add_argument("--crash-recovery", action="store_true", help="synthetic active/background WebKit process kills and POST recovery")
    options = parser.parse_args()
    if options.lifecycle and options.public_media:
        parser.error("--lifecycle and --public-media are separate passes")
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
        print("TEST EXECUTABLE sha256=" + hashlib.sha256(executable.read_bytes()).hexdigest(), flush=True)
        print(message + " Requires a graphical session.", flush=True)
        try:
            try:
                command = [str(executable), "browsercheck"] + (["--lifecycle"] if options.lifecycle else [])
                if options.public_media:
                    command.append("--public-media")
                if options.crash_recovery:
                    command.append("--crash-recovery")
                browser_code = run_fixture(command, environment, app, 620 if options.lifecycle or options.public_media else 75)
            except subprocess.TimeoutExpired:
                print("FAIL: browser smoke process exceeded its deadline", file=sys.stderr)
                browser_code = 1

            # WebKit's network process holds the named data store open throughout the
            # browsercheck invocation. Re-enter the same signed app after it exits to
            # unregister the isolated store and verify that WebKit no longer lists it.
            try:
                cleanup_code = run_fixture([str(executable), "browsercheck-cleanup"], environment, app, 20)
            except subprocess.TimeoutExpired:
                print("FAIL: browser smoke cleanup exceeded 20 seconds", file=sys.stderr)
                cleanup_code = 1
            return browser_code or cleanup_code
        finally:
            if bundle_context is not None:
                bundle_context.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
