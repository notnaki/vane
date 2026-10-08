#!/usr/bin/env python3
"""Signed sandbox download: quit through AppKit, restart, resume, compare SHA-256.
Requires a built debug executable and a logged-in macOS session. No user data touched.
"""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import uuid
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("browser_smoke", ROOT / "scripts/check-browser-smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
BODY = bytes(i % 251 for i in range(262144))

class Handler(http.server.BaseHTTPRequestHandler):
    released = threading.Event()
    ranges = []
    def log_message(self, *args):
        pass
    def do_GET(self):
        value = self.headers.get("Range")
        type(self).ranges.append(value)
        start = int(value.split("=")[1].split("-")[0]) if value else 0
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", "attachment; filename=restart.bin")
        self.send_header("Content-Length", str(len(BODY) - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"fixture-v1"')
        self.send_header("Last-Modified", "Wed, 07 Oct 2026 10:00:00 GMT")
        if value:
            self.send_header("Content-Range", f"bytes {start}-{len(BODY)-1}/{len(BODY)}")
        self.end_headers()
        try:
            self.wfile.write(BODY[start:start + 16384])
            self.wfile.flush()
            if not self.released.wait(30):
                return
            self.wfile.write(BODY[start + 16384:])
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = ROOT / ".build/debug/vane"
    if not binary.is_file():
        raise SystemExit("Build the debug executable first")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="vane-downloadcheck-") as bundle, tempfile.TemporaryDirectory(prefix=".vane-downloadcheck-", dir=Path.home() / "Downloads") as data:
            app = Path(bundle) / "Vane Download Check.app"
            executable = app / "Contents/MacOS/vane"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binary, executable)
            info = {"CFBundleIdentifier": "io.github.notnaki.vane.downloadcheck." + uuid.uuid4().hex,
                    "CFBundleExecutable": "vane", "CFBundleName": "Vane Download Check",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
                    "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0"}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            print(f"TEST BUNDLE identifier={info['CFBundleIdentifier']}", flush=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(ROOT / "Vane.entitlements"), str(app)], check=True)
            env = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if k in os.environ}
            env["VANE_DOWNLOAD_FIXTURE_URL"] = f"http://127.0.0.1:{server.server_port}/file"
            print(f"TEST SERVER loopback port={server.server_port}; executable sha256={hashlib.sha256(executable.read_bytes()).hexdigest()}", flush=True)
            for phase in ("quit-running", "quit-pause-pending"):
                fixture = Path(data) / phase
                fixture.mkdir()
                env["VANE_DATA_DIR"] = str(fixture)
                env["VANE_DOWNLOAD_FIXTURE_PAUSE_FIRST"] = "1" if phase == "quit-pause-pending" else "0"
                Handler.released.clear()
                Handler.ranges.clear()
                try:
                    if smoke.run_fixture([str(executable), "browsercheck", "--download-pause"], env, app, 40):
                        raise RuntimeError("Quit phase failed")
                    index = fixture / "downloads.json"
                    rows = json.loads(index.read_bytes())
                    assert len(rows) == 1 and rows[0]["state"] == "paused", rows
                    blob = fixture / "downloads-resume" / rows[0]["resumeFile"]
                    assert blob.is_file() and blob.stat().st_size > 8
                    Handler.released.set()
                    if smoke.run_fixture([str(executable), "browsercheck", "--download-resume"], env, app, 40):
                        raise RuntimeError("Restart phase failed")
                    rows = json.loads(index.read_bytes())
                    assert len(rows) == 1 and rows[0]["state"] == "done", rows
                    files = list((fixture / "files").iterdir())
                    assert len(files) == 1, files
                    assert hashlib.sha256(files[0].read_bytes()).digest() == hashlib.sha256(BODY).digest()
                    assert not blob.exists()
                    assert any(Handler.ranges), Handler.ranges
                    print(f"PASS {phase}: final SHA-256, destination, persisted completion, Range request and resume cleanup", flush=True)
                finally:
                    code = smoke.run_fixture([str(executable), "browsercheck-cleanup"], env, app, 25)
                    if code:
                        raise RuntimeError("WebKit fixture cleanup failed")
    finally:
        Handler.released.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        print("TEST SERVER stopped; temporary bundle/files removed", flush=True)

if __name__ == "__main__":
    main()
