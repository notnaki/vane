#!/usr/bin/env python3
"""SPI-assisted page-backed worker reduction, independent of Vane/extensions.

Request headers are observations, not measurements of SWServer's origin-UA map.
Eight fresh sandboxed hardened launches at most; preserve the first failure.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("owned_ua_runner", Path(__file__).with_name("check-extension-ua.py"))
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15"
IDENTITIES = (SAFARI, "Vane Prior Worker Identity/1.0 (no Safari token)", SAFARI)
PREFIX = b"PAGE WORKER "

def records(output):
    result = []
    for line in output.splitlines(keepends=True):
        if not line.startswith(PREFIX): continue
        if not line.endswith(b"\n") or len(line) > 65536: raise ValueError("Unbounded or incomplete native record")
        value = json.loads(line[len(PREFIX):])
        if not isinstance(value, dict): raise ValueError("Native record must be an object")
        result.append(value)
    return result

def validate_primary(output, store):
    values = records(output)
    if len(values) != 14: raise ValueError("Expected launch, three full stages and completion")
    launch = values[0]
    if (launch.get("event") != "launch" or launch.get("scenario") != "page-backed-three-stage"
            or launch.get("store") != store or any(launch.get(key) is not True for key in ("appRunning", "finishedLaunching"))):
        raise ValueError("Missing bound completed application launch")
    nonces = set()
    for stage, expected in enumerate(IDENTITIES):
        start, first, second, comparison = values[1+stage*4:5+stage*4]
        nonce = start.get("nonce")
        if (not isinstance(nonce, str) or str(uuid.UUID(nonce)) != nonce or uuid.UUID(nonce).version != 4 or nonce in nonces):
            raise ValueError("Fresh canonical context nonce required")
        nonces.add(nonce)
        if start.get("event") != "stage" or start.get("expected") != expected: raise ValueError("Missing selected stage")
        if (comparison.get("event") != "comparison" or comparison.get("matches") is not True
                or any(comparison.get(key) != expected for key in ("expected", "startup", "current", "viewUA"))
                or comparison.get("href") != f"vane-worker-control://{nonce}/worker.js"):
            raise ValueError("Worker startup/current UA did not match its configured view")
        for request, kind, field in [(first, "script", "scriptRequestUA"), (second, "report", "reportRequestUA")]:
            header = request.get("UA")
            if (request.get("event") != "request" or request.get("kind") != kind or not isinstance(header, str)
                    or len(header) > 8192 or comparison.get(field) != header):
                raise ValueError("Unbound request-header observation")
        for item in (start, first, second, comparison):
            if type(item.get("stage")) is not int or item["stage"] != stage or item.get("nonce") != nonce:
                raise ValueError("Wrong context or stage")
    if values[-1] != {"event": "complete", "verified": 3, "store": store}: raise ValueError("Missing complete coverage")

def validate_cleanup(output, store):
    values = records(output)
    if (values != [{"event": "cleanup", "store": store, "retired": True, "error": ""}]
            or values[0].get("retired") is not True):
        raise ValueError("Exact post-exit store retirement unverified")

def run_trial(binary, bundle_root, logs, interrupted, invoke=owned.run_ua_process):
    bundle = bundle_root / "Page Worker UA Check.app"
    executable = bundle / "Contents/MacOS/PageWorkerUA"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    identifier = "io.github.notnaki.vane.framework-worker-check." + uuid.uuid4().hex
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable.name, "CFBundleName": "Page Worker UA Check", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0"}))
    store = str(uuid.uuid4())
    (logs / "run.json").write_text(json.dumps({"bundle": str(bundle), "store": store,
        "binarySHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}, sort_keys=True) + "\n")
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if key in os.environ}
    environment.update(PAGE_WORKER_STORE=store, PAGE_WORKER_PHASE="primary")
    for name, arguments in [("signing", ["--force", "--sign", "-", "--options", "runtime", "--entitlements",
                                        str(ROOT / "Tests/Diagnostics/PublicWorkerUA/Entitlements.plist"), str(bundle)]),
                            ("signature", ["--verify", "--strict", str(bundle)])]:
        status, exited, _ = invoke(["/usr/bin/codesign", *arguments], environment, 30, logs / (name + ".log"), interrupted)
        if status or not exited: return status or 1
    status, exited, output = invoke([str(executable)], environment, 65, logs / "primary.log", interrupted)
    if not exited:
        print(f"FAIL primary exit unverified; store {store} and bundle {bundle} retained", flush=True)
        return status or 1
    if not status:
        try: validate_primary(output, store)
        except ValueError as error:
            print(f"FAIL primary attestation: {error}", flush=True); status = 1
    environment["PAGE_WORKER_PHASE"] = "cleanup"
    pending = interrupted[0]; interrupted[0] = None
    cleanup_status, cleanup_exited, cleanup_output = invoke([str(executable)], environment, 20, logs / "cleanup.log", interrupted)
    if not cleanup_status and cleanup_exited:
        try: validate_cleanup(cleanup_output, store)
        except ValueError as error:
            print(f"FAIL cleanup attestation: {error}", flush=True); cleanup_status = 1
    else: cleanup_status = cleanup_status or 1
    if cleanup_status: print(f"FAIL exact store retirement; store {store} and bundle {bundle} retained", flush=True)
    if pending: status = status or 128 + pending
    return status or cleanup_status

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    args = parser.parse_args()
    if not args.binary.is_file(): parser.error("requires compiled native reduction")
    evidence = args.evidence_dir.resolve(); evidence.mkdir(mode=0o700)
    interrupted = [None]
    previous = {sig: signal.signal(sig, lambda signum, frame: interrupted.__setitem__(0, signum)) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for trial in range(1, 9):
            if interrupted[0]: return 128 + interrupted[0]
            logs = evidence / f"trial-{trial:02d}"; logs.mkdir(mode=0o700)
            bundle_root = Path(tempfile.mkdtemp(prefix="vane-page-worker-ua-")).resolve()
            print(f"PAGE WORKER trial {trial}/8 bundleRoot={bundle_root}", flush=True)
            status = run_trial(args.binary.resolve(), bundle_root, logs, interrupted)
            if status: return status
            print(f"PASS PAGE WORKER trial {trial}: three bound stages and exact post-exit retirement", flush=True)
        print("Finite page-backed cohort passed; original extension failures remain unresolved", flush=True)
        return 0
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)

if __name__ == "__main__": sys.exit(main())
