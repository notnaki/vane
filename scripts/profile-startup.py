#!/usr/bin/env python3
"""Opt-in startup measurements with isolated synthetic sessions and a loopback page.

Use an optimized executable built before reserving a quiet profiling window.
The first launch is process-cold, not an OS-cache purge. Every subsequent launch
uses equivalent freshly seeded session bytes. No routine CI timing thresholds.
"""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time
import uuid

PROFILE = "00000000-0000-0000-0000-000056616E65"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--sizes", type=int, nargs="+", default=[10, 100, 500, 1000])
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1 or any(size < 1 for size in args.sizes):
        parser.error("runs and session sizes must be positive")
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    data = Path.home() / "Downloads" / (".vane-startup-fixture-" + uuid.uuid4().hex)
    data.mkdir()
    app = evidence / "Vane Startup Fixture.app"
    executable = app / "Contents/MacOS/vane"
    executable.parent.mkdir(parents=True)
    shutil.copy2(args.binary.resolve(), executable)
    resources = app / "Contents/Resources"
    resources.mkdir()
    for bundle in args.binary.resolve().parent.glob("Vane_vane.bundle"):
        shutil.copytree(bundle, resources / bundle.name)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "io.github.notnaki.vane.startupfixture." + uuid.uuid4().hex,
        "CFBundleExecutable": "vane", "CFBundleName": "Vane Startup Fixture",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0"}))
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                    str(root / "Vane.entitlements"), str(app)], check=True)
    ready = threading.Event()
    page_requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/tab/"):
                page_requests.append(self.path)
            if self.path.startswith("/ready"):
                ready.set()
            body = b"<title>Startup fixture</title><h1>Local synthetic page</h1><script>requestAnimationFrame(()=>requestAnimationFrame(()=>fetch('/ready')))</script>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if key in os.environ}
    env["VANE_DATA_DIR"] = str(data)
    instances = []
    try:
        for count in args.sizes:
            for run in range(args.runs):
                for name in ["running", "session.json.previous"]:
                    (data / name).unlink(missing_ok=True)
                space = str(uuid.uuid4()).upper()
                rows = [{"id": str(uuid.uuid4()).upper(),
                         "url": f"http://127.0.0.1:{server.server_port}/tab/{index}",
                         "title": f"Synthetic tab {index}", "kind": 2} for index in range(count)]
                files = {
                    "profiles.json": {"profiles": [{"id": PROFILE, "name": "Startup Fixture", "colorHex": "#6E7DD2"}], "activeID": PROFILE},
                    "spaces.json": [{"id": space, "profileID": PROFILE, "name": "Startup Fixture", "tabURLs": [r["url"] for r in rows], "pinnedURLs": [], "icon": "cloud"}],
                    "session.json": {"version": 4, "windows": [rows], "spaces": [space], "selected": [rows[-1]["id"]]}}
                for name, value in files.items():
                    (data / name).write_text(json.dumps(value))
                ready.clear()
                page_requests.clear()
                with (evidence / f"app-{count}-{run}.log").open("w") as log:
                    start = time.monotonic()
                    process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
                    instance = {"pid": process.pid, "start": subprocess.run(["ps", "-p", str(process.pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip(),
                                "bundle": str(app), "data": str(data), "launched_utc": datetime.now(timezone.utc).isoformat(), "count": count, "run": run}
                    instances.append(instance)
                    (evidence / "instances.json").write_text(json.dumps(instances, indent=2))
                    try:
                        if not ready.wait(45):
                            raise RuntimeError(f"First-page readiness timed out: {instance}")
                        result = {"count": count, "run": run, "launch_to_two_page_frames_ms": (time.monotonic() - start) * 1000, "page_requests": list(page_requests)}
                        if page_requests != [f"/tab/{count - 1}"]:
                            raise RuntimeError(f"Unexpected restored page requests: {result}")
                        print(json.dumps(result), flush=True)
                        with (evidence / "measurements.jsonl").open("a") as output:
                            output.write(json.dumps(result) + "\n")
                    finally:
                        # Owned unreaped child: its PID cannot have been reused. Revalidate
                        # the executable and launch immediately before sending TERM.
                        if process.poll() is None:
                            current = subprocess.run(["ps", "-p", str(process.pid), "-o", "lstart=,comm="], capture_output=True, text=True).stdout
                            if instance["start"] not in current or str(executable) not in current:
                                raise RuntimeError(f"Owned process identity changed: {instance}")
                            process.terminate()
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                current = subprocess.run(["ps", "-p", str(process.pid), "-o", "lstart=,comm="], capture_output=True, text=True).stdout
                                if instance["start"] not in current or str(executable) not in current:
                                    raise RuntimeError(f"Owned process identity changed: {instance}")
                                process.kill()
                                process.wait()
                        instance["exited"] = True
                        instance["exit_code"] = process.returncode
                        (evidence / "instances.json").write_text(json.dumps(instances, indent=2))
                        time.sleep(0.5)  # Let the owned WebKit children finish teardown.
    finally:
        server.shutdown()
    print(f"All tracked fixture processes exited. Synthetic data retained at {data}", flush=True)


if __name__ == "__main__":
    main()
