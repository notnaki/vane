#!/usr/bin/env python3
"""Interrupt disposable signed Vane copies; never read a real browser profile."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid


def wait_for(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError("fixture timed out")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--binary", type=Path, default=root / ".build/debug/vane")
    options = parser.parse_args()
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            data = b"<title>Recovery fixture</title><form><input name=draft></form>"
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    owned = []
    with tempfile.TemporaryDirectory(prefix="vane-recovery-app-") as bundle_dir, \
            tempfile.TemporaryDirectory(prefix=".vane-recovery-", dir=Path.home() / "Downloads") as data_dir:
        app = Path(bundle_dir) / "Vane Recovery Check.app"
        executable = app / "Contents/MacOS/vane"
        executable.parent.mkdir(parents=True)
        shutil.copy2(options.binary, executable)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.github.notnaki.vane.recoverycheck." + uuid.uuid4().hex,
            "CFBundleExecutable": "vane", "CFBundleName": "Vane Recovery Check",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "26.0", "NSPrincipalClass": "NSApplication",
        }))
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                        str(root / "Vane.entitlements"), str(app)], check=True)
        environment = {name: os.environ[name] for name in
                       ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if name in os.environ}
        environment["VANE_DATA_DIR"] = data_dir
        print("TEST EXECUTABLE sha256=" + hashlib.sha256(executable.read_bytes()).hexdigest(), flush=True)

        def launch():
            process = subprocess.Popen([str(executable)], env=environment)
            start = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "lstart="], text=True).strip()
            owned.append((process, start))
            print(f"TEST PROCESS bundle={app} pid={process.pid} start={start}", flush=True)
            return process

        def stop(process, start, sig):
            if process.poll() is not None:
                return
            current = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "lstart=,comm="], text=True).strip()
            assert start in current and str(executable) in current, "owned process identity changed"
            process.send_signal(sig)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop(process, start, signal.SIGKILL)
            assert process.poll() is not None
            print(f"TEST PROCESS exited pid={process.pid} code={process.returncode}", flush=True)

        directory = Path(data_dir)
        session = directory / "session.json"
        url = f"http://127.0.0.1:{server.server_port}/saved"
        # Legacy data exercises migration as well as early restoration interruption.
        original = json.dumps([[url]]).encode()
        session.write_bytes(original)
        try:
            first = launch()
            wait_for(lambda: (directory / "running").exists() and "/saved" in requests)
            stop(first, owned[-1][1], signal.SIGKILL)  # Finder Force Quit has the same signal.
            assert (directory / "running").exists()
            completed = session.read_bytes()
            for sig in [signal.SIGTERM, signal.SIGKILL, signal.SIGKILL]:
                before = len(requests)
                preserved = {p: p.read_bytes() for p in (directory / "Session Recovery").glob("*/session.json")}
                process = launch()
                time.sleep(1.5)
                assert process.poll() is None, "recovery app exited during startup"
                wait_for(lambda: "/saved" in requests[before:])
                originals = list((directory / "Session Recovery").glob("*/session.json"))
                assert len(originals) == len(preserved) + 1, "unclean launch did not preserve its originals"
                assert all(p.read_bytes() == data for p, data in preserved.items()), "a recoverable original was overwritten"
                assert any(p.read_bytes() == completed for p in originals), "last completed snapshot was lost"
                stop(process, owned[-1][1], sig)
            originals = list((directory / "Session Recovery").glob("*/session.json"))
            assert len(originals) == 3 and any(p.read_bytes() == completed for p in originals)
            print("PASS SIGKILL, SIGTERM, three repeated restoration interruptions; originals retained; selected page restored on every restart", flush=True)
        finally:
            for process, start in owned:
                stop(process, start, signal.SIGTERM)
            cleanup = subprocess.Popen([str(executable), "browsercheck-cleanup"], env=environment)
            start = subprocess.check_output(["ps", "-p", str(cleanup.pid), "-o", "lstart="], text=True).strip()
            print(f"TEST PROCESS bundle={app} pid={cleanup.pid} start={start} cleanup", flush=True)
            try:
                assert cleanup.wait(timeout=20) == 0, "WebKit fixture cleanup failed"
            finally:
                stop(cleanup, start, signal.SIGTERM)
            print("PASS all owned app processes exited", flush=True)
            server.shutdown()


if __name__ == "__main__":
    main()
