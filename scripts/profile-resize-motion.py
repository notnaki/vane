#!/usr/bin/env python3
"""Opt-in owned sidebar CPU capture. Run only in a coordinated foreground slot.

The unchanged motion assertions still run, but sampling perturbs scheduling:
this command produces diagnostic evidence, never an accepted cadence pass.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("native_fixture_runner", Path(__file__).with_name("run-native-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def validate_record(record, token, bundle, sidebar=True):
    if (not isinstance(record, dict) or record.get("schema") != 1 or record.get("token") != token
            or record.get("sidebar") is not sidebar or record.get("testBundlePath") != bundle):
        raise ValueError("profile stage does not belong to the selected resize fixture")
    ready = record.get("readyAt")
    if type(ready) not in (int, float) or not math.isfinite(ready) or ready <= 0:
        raise ValueError("profile stage has no monotonic start")
    for role in ("ui", "content"):
        process = record.get(role)
        if (not isinstance(process, dict)
                or any(type(process.get(key)) is not int or process[key] <= 0 for key in ("pid", "start"))
                or not runner._absolute(process.get("path"))):
            raise ValueError("profile stage has no exact " + role + " identity")
    content = record["content"]["path"]
    if (not content.startswith("/System/") or "/WebKit.framework/" not in content
            or Path(content).name != "com.apple.WebKit.WebContent"
            or record["ui"]["pid"] == record["content"]["pid"]):
        raise ValueError("profile content is not the fixture's distinct system WebContent")
    return record


def require_identity(captured, identify=runner.process_identity):
    observed = identify(captured["pid"])
    if observed is None or any(observed.get(key) != captured[key] for key in ("pid", "start", "path")):
        raise ValueError("profile target exited or changed identity; sampling refused/discarded")


def validate_finished(ready, finished):
    if any(finished.get(key) != ready[key] for key in ready) or finished.get("ownershipHeld") is not True:
        raise ValueError("fixture ownership changed during profiling")
    began, ended = finished.get("began"), finished.get("ended")
    if (type(began) not in (int, float) or type(ended) not in (int, float)
            or not math.isfinite(began) or not math.isfinite(ended)
            or not ready["readyAt"] <= began < ended):
        raise ValueError("profile did not cover a completed motion interval")


def validate_overlap(collection, finished):
    # Process lifetimes must overlap the drag. Attachment and symbolication can
    # extend them, so reports still determine the exact sampled work.
    samplers = collection.get("samplers") if isinstance(collection, dict) else None
    if (not isinstance(samplers, list) or len(samplers) != 2
            or any(not isinstance(entry, dict) for entry in samplers)
            or {entry.get("role") for entry in samplers} != {"ui", "content"}):
        raise ValueError("profile has no completed UI/content collection")
    for entry in samplers:
        launched, returned = entry.get("launchedAt"), entry.get("returnedAt")
        if (type(entry.get("status")) is not int or entry["status"] != 0
                or any(type(value) not in (int, float) or not math.isfinite(value)
                       for value in (launched, returned))
                or launched >= returned
                or max(launched, finished["began"]) >= min(returned, finished["ended"])):
            raise ValueError("owned " + entry["role"] + " collection did not overlap the drag")


def write_private(path, value):
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output: json.dump(value, output, indent=2)
    os.replace(temporary, path)


def collect(record, directory, launch=subprocess.Popen, identify=runner.process_identity):
    """Only sample the two getter-owned identities. Never enumerate processes."""
    children = []
    logs = []
    metadata = {"diagnosticOnly": True, "durationSeconds": 2, "intervalMilliseconds": 1, "samplers": []}
    try:
        for role in ("ui", "content"): require_identity(record[role], identify)
        for role in ("ui", "content"):
            captured = record[role]
            require_identity(captured, identify)
            report = directory / (role + ".sample.txt")
            log = (directory / (role + ".sampler.log")).open("xb")
            logs.append(log)
            # The fixture keeps these exact processes alive until collection ends.
            # -mayDie loads symbols BEFORE sampling and can miss the whole cold
            # first viewport; symbolize after collecting its stacks instead.
            child = launch(["/usr/bin/sample", str(captured["pid"]), "2", "1", "-file", str(report)],
                           stdout=log, stderr=subprocess.STDOUT)
            children.append(child)
            metadata["samplers"].append({"role": role, "target": captured, "samplerPID": child.pid,
                                         "launchedAt": time.monotonic(), "report": str(report)})
        deadline = time.monotonic() + 20
        for child, entry in zip(children, metadata["samplers"]):
            entry["status"] = child.wait(timeout=max(0.01, deadline - time.monotonic()))
            entry["returnedAt"] = time.monotonic()
            require_identity(entry["target"], identify)
            if entry["status"] != 0 or not Path(entry["report"]).is_file():
                raise ValueError("owned " + entry["role"] + " sampler failed; inspect collection metadata")
        return metadata
    finally:
        for child in children:
            # Popen owns this unreaped sampler child; never signal a sampled target.
            runner.stop_primary_driver(child)
        for log in logs: log.close()
        write_private(directory / "collection.json", metadata)


def main(arguments):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, help="new directory for retained private evidence")
    parser.add_argument("--motion", choices=("sidebar", "window"), default="sidebar")
    options = parser.parse_args(arguments)
    if sys.platform != "darwin": raise SystemExit("native profiling requires macOS")
    root = Path(__file__).resolve().parent.parent
    bundles = [root / ".build/debug" / name for name in ("VaneTests.xctest", "VanePackageTests.xctest")]
    bundles = [path.resolve() for path in bundles if path.is_dir()]
    if len(bundles) != 1: raise SystemExit("build one current debug test bundle before profiling")
    directory = Path(options.output_dir).absolute()
    directory.mkdir(mode=0o700)  # Refuse to overwrite any previous attempt.
    directory = directory.resolve()
    token = uuid.uuid4().hex
    write_private(directory / "contract.json", {"schema": 1, "token": token})
    environment = dict(os.environ, VANE_RESIZE_PROFILE_DIR=str(directory), VANE_RESIZE_PROFILE_TOKEN=token,
                       VANE_RESIZE_RESPONSIVE_MOTION="1", VANE_RESIZE_TIMING="1",
                       VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT="120")
    kind = "Sidebar" if options.motion == "sidebar" else "Window"
    selector = f"WindowResizeResponsiveMotionTests.testResponsivePageKeepsVisible{kind}MovementWithinTheFrameBudget"
    command = [sys.executable, str(root / "scripts/run-native-tests.py"), "--skip-build", "--filter", selector]
    print("RESIZE_PROFILE diagnosticOnly=true evidence=" + str(directory), flush=True)
    driver = subprocess.Popen(command, cwd=root, env=environment)
    status = 1
    ready = None
    collection = None
    try:
        deadline = time.monotonic() + 90
        while not (directory / "ready.json").exists():
            if driver.poll() is not None: raise ValueError("fixture exited before profiling admission")
            if time.monotonic() >= deadline: raise ValueError("profile admission timed out")
            time.sleep(0.01)
        ready = validate_record(runner.read_private_json(directory / "ready.json"), token, str(bundles[0]),
                                sidebar=options.motion == "sidebar")
        collection = collect(ready, directory)
        status = 0
    except KeyboardInterrupt:
        driver.send_signal(signal.SIGINT)
        print("RESIZE_PROFILE interrupted", file=sys.stderr, flush=True)
    except Exception as error:
        print("RESIZE_PROFILE collection failed: " + str(error), file=sys.stderr, flush=True)
    finally:
        write_private(directory / "release.json", {"schema": 1, "token": token, "status": status})
    primary = driver.wait()  # The native wrapper owns bounded retirement and cleanup.
    try:
        if ready is None: raise ValueError("no admitted fixture metadata")
        finished = runner.read_private_json(directory / "finished.json")
        validate_finished(ready, finished)
        validate_overlap(collection, finished)
    except Exception as error:
        status = 1
        print("RESIZE_PROFILE final validation failed: " + str(error), file=sys.stderr, flush=True)
    print(f"RESIZE_PROFILE diagnosticOnly=true collectionStatus={status} nativeStatus={primary}", flush=True)
    return primary if primary else status


if __name__ == "__main__": raise SystemExit(main(sys.argv[1:]))
