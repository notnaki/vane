#!/usr/bin/env python3
"""Run fake-display lifecycle in an isolated app host and clean up only its process."""
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time


def identity(pid):
    return subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
                          text=True, capture_output=True, check=False).stdout.strip()


def main():
    source = Path(__file__).resolve().parent / "fixtures/permission-display.swift"
    with tempfile.TemporaryDirectory(prefix="vane-permission-display-") as temporary:
        root = Path(temporary)
        bundle = root / "VanePermissionDisplayTest.app"
        executable = bundle / "Contents/MacOS/permission-display"
        executable.parent.mkdir(parents=True)
        with (bundle / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "io.github.notnaki.vane.permission-display-fixture",
                          "CFBundleName": "VanePermissionDisplayTest", "CFBundleExecutable": executable.name,
                          "CFBundlePackageType": "APPL", "LSUIElement": True}, stream)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(source), "-o", str(executable)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)
        result = root / "result.json"
        # Launch directly so its PID is known before any UI or WebKit work begins.
        process = subprocess.Popen([str(executable), str(result)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        launch = identity(process.pid)
        print(f"Task-owned display fixture: bundle={bundle}, pid={process.pid}, launch={launch}", flush=True)
        try:
            deadline = time.monotonic() + 45
            while not result.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not result.exists():
                raise RuntimeError("Display fixture exited or timed out without a result")
            outcome = json.loads(result.read_text())
            print(json.dumps(outcome, sort_keys=True))
            if not outcome.get("passed"):
                raise RuntimeError(outcome.get("error", "Display fixture failed"))
        finally:
            # Exact PID + executable + start time guards against PID reuse. This fixture
            # has no quit-confirmation preference; never target another Vane instance.
            if process.poll() is None:
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    if identity(process.pid) != launch or str(executable) not in launch:
                        raise RuntimeError("Fixture identity changed; refusing to signal it")
                    process.send_signal(signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        if identity(process.pid) != launch:
                            raise RuntimeError("Fixture PID was reused; refusing to kill it")
                        process.kill()
                        process.wait(timeout=2)
            if process.poll() is None:
                raise RuntimeError(f"Fixture {process.pid} remains running")
            print(f"Verified task-owned display fixture {process.pid} exited", flush=True)


if __name__ == "__main__":
    main()
