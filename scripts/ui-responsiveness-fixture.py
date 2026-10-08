#!/usr/bin/env python3
"""Launch an isolated native release fixture for manual UI/profiler comparisons.

Use Ctrl-C to stop the owned app/server. Evidence and synthetic data are retained.
No user profile, network website, credentials or global preferences are used.
"""
import argparse
from datetime import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid

PROFILE = "00000000-0000-0000-0000-000056616E65"


def seed(directory, port, large):
    directory.mkdir()
    base = f"http://127.0.0.1:{port}"
    def write(name, value):
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value))
    spaces, windows = [], []
    for n in range(10 if large else 2):
        sid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"vane-ui-space-{n}")).upper()
        rows = [{"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"vane-ui-tab-{n}-{t}")).upper(),
                 "url": f"{base}/page.html?space={n}&tab={t}", "title": f"Fixture {n + 1} Tab {t + 1}",
                 "kind": 1 if t < 8 else 2} for t in range(20 if large else 4)]
        spaces.append({"id": sid, "profileID": PROFILE, "name": f"Fixture {n + 1}",
                       "tabURLs": [r["url"] for r in rows if r["kind"] == 2],
                       "pinnedTabURLs": [r["url"] for r in rows if r["kind"] == 1],
                       "pinnedURLs": [f"{base}/page.html?favorite={f}" for f in range(4)],
                       "icon": "cloud", "colorHex": "#6E7DD2"})
        windows.append(rows)
    write("profiles.json", {"profiles": [{"id": PROFILE, "name": "UI Fixture", "colorHex": "#6E7DD2"}], "activeID": PROFILE})
    write("spaces.json", spaces)
    layout = {"tabs": [{"id": r["id"], "url": r["url"], "kind": r["kind"], "title": r["title"]} for r in windows[0]],
              "pins": {"entries": [{"row": {"tab": {"_0": r["id"]}}} for r in windows[0] if r["kind"] == 1]},
              "today": {"entries": [{"row": {"tab": {"_0": r["id"]}}} for r in windows[0] if r["kind"] == 2]},
              "splits": [], "selected": windows[0][0]["id"], "omitted": 0}
    write("space-templates.json", {"version": 1, "profileID": PROFILE, "templates": [{
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, "vane-ui-template")), "name": "Fixture template",
        "profileID": PROFILE, "modified": 812900000, "appearance": {"icon": "cloud"}, "layout": layout}]})
    # Two windows in one Space exercise actual shared-page ownership. Remaining
    # Spaces load on navigation; this avoids 10 artificial visible browser windows.
    write("session.json", {"version": 4, "windows": [windows[0], windows[0]],
                           "spaces": [spaces[0]["id"], spaces[0]["id"]],
                           "selected": [windows[0][0]["id"], windows[0][0]["id"]]})
    connection = sqlite3.connect(directory / "vane.db")
    connection.execute("CREATE TABLE visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL)")
    connection.executemany("INSERT INTO visits(url,title,at) VALUES(?,?,?)",
        [(f"{base}/page.html?history={n}", f"Synthetic history entry {n} common", 1791400000 - n * 60)
         for n in range(10000 if large else 100)])
    connection.commit(); connection.close()
    items = [{"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"vane-ui-item-{n}")), "kind": "note",
              "text": f"Synthetic note {n}\nDrag and edit this card.", "source": "", "points": [],
              "color": "yellow", "x": 120 + n % 10 * 300, "y": 120 + n // 10 * 230,
              "width": 280, "height": 200} for n in range(100 if large else 6)]
    write(f"easels-{PROFILE}.json", {"version": 1, "boards": [{"version": 1,
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, "vane-ui-board")), "title": "Populated fixture",
        "modified": 812900000, "items": items}]})
    for n in range(20 if large else 2):
        aid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"vane-ui-article-{n}"))
        write(f"ReadingQueue/{PROFILE.lower()}/{aid}/article.json", {
            "version": 1, "id": aid, "profileID": PROFILE, "title": f"Offline fixture {n}",
            "sourceURL": f"{base}/page.html?article={n}", "capturedAt": 812900000 - n,
            "isRead": False, "byline": "Synthetic fixture", "resources": [], "missingImages": 0,
            "nodes": [{"e": "p", "c": [{"x": "Offline text for searching and reading. " * 100}]}]})
    return base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--large", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    evidence = args.evidence.resolve(); evidence.mkdir(parents=True, exist_ok=False)
    web = evidence / "web"; web.mkdir()
    (web / "page.html").write_text("""<!doctype html><title>Synthetic page</title>
<style>body{font:18px system-ui;padding:40px;max-width:650px}p{line-height:1.6}</style>
<h1>Synthetic local page</h1><input placeholder='Unfinished form' value='Keep this draft'>
<p>This fixture stays on this Mac. It is used for window ownership, typing and layout.</p>
<article><h2>Offline reading fixture</h2>""" + "<p>Readable synthetic article content. Test navigation and continuity without using an account.</p>" * 60 + "</article>")
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(web)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Downloads is covered by the app's existing sandbox entitlement.
    data = Path.home() / "Downloads" / (".vane-ui-fixture-" + uuid.uuid4().hex)
    seed(data, server.server_port, args.large)
    app = evidence / "Vane UI Fixture.app"
    executable = app / "Contents/MacOS/vane"; executable.parent.mkdir(parents=True)
    shutil.copy2(args.binary.resolve(), executable)
    resources = app / "Contents/Resources"; resources.mkdir()
    candidates = list(args.binary.resolve().parent.glob("Vane_vane.bundle"))
    if not candidates:
        candidates = list((args.binary.resolve().parent.parent / "Resources").glob("Vane_vane.bundle"))
    for bundle in candidates:
        shutil.copytree(bundle, resources / bundle.name)
    info = {"CFBundleIdentifier": "io.github.notnaki.vane.uifixture." + uuid.uuid4().hex,
            "CFBundleExecutable": "vane", "CFBundleName": "Vane UI Fixture", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(root / "Vane.entitlements"), str(app)], check=True)
    h = 5381
    for byte in str(data).encode(): h = (h * 33 + byte) & ((1 << 64) - 1)
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"; encoded = ""
    while h: encoded = alphabet[h % 36] + encoded; h //= 36
    suite = "vane.datadir." + encoded
    # Sandboxed preferences belong to the signed app's container. Host `defaults`
    # writes do not configure that domain; retain native defaults for both runs.
    env = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if key in os.environ}
    env["VANE_DATA_DIR"] = str(data)
    with (evidence / "app.log").open("w") as log:
        process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
        try:
            started = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "lstart="], text=True).strip()
            metadata = {"pid": process.pid, "start": started, "bundle": str(app), "data": str(data),
                        "suite": suite, "large": args.large, "launched": datetime.now().isoformat(),
                        "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
            (evidence / "instance.json").write_text(json.dumps(metadata, indent=2)); print(json.dumps(metadata), flush=True)
            with (evidence / "resources.tsv").open("w") as samples:
                while process.poll() is None:
                    snapshot = subprocess.run(["ps", "-p", str(process.pid), "-o", "pid=,pcpu=,rss=,time="], text=True, capture_output=True)
                    if snapshot.returncode: break
                    samples.write(f"{time.monotonic():.3f}\t{snapshot.stdout.strip()}\n"); samples.flush()
                    time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            # Every exceptional exit must stop this owned, unreaped child. Its PID
            # cannot have been reused. Never wait indefinitely on a live fixture.
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            process.wait()
            print(f"TEST PROCESS exited pid={process.pid} code={process.returncode}", flush=True)
            server.shutdown()
            cleanup = subprocess.Popen([str(executable), "browsercheck-cleanup"], env=env)
            try:
                started = subprocess.run(["ps", "-p", str(cleanup.pid), "-o", "lstart="], text=True, capture_output=True).stdout.strip()
                (evidence / "cleanup-instance.json").write_text(json.dumps({"pid": cleanup.pid, "start": started, "bundle": str(app)}))
                cleanup.wait(timeout=20)
            except subprocess.TimeoutExpired:
                pass
            finally:
                if cleanup.poll() is None:
                    cleanup.terminate()
                    try: cleanup.wait(timeout=5)
                    except subprocess.TimeoutExpired: cleanup.kill(); cleanup.wait()
            print(f"WebKit cleanup code={cleanup.returncode}; retained synthetic data={data}", flush=True)


if __name__ == "__main__": main()
