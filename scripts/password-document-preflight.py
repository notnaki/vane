#!/usr/bin/env python3
"""Temporary diagnostic preflight. A passing sample is not merge validation.

The unchanged native runner owns test/backend retirement. This supervisor only
samples identities positively attributed to its private manifest and the tested
WKWebView; it never sends a signal to a native test host or WebContent process.
"""
import argparse
import concurrent.futures
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
TARGET = "VaneTests.PasswordAutofillTests/testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep"
PROCESS = "PASSWORD DOCUMENT PROCESS "
COMMIT = "PASSWORD DOCUMENT COMMIT "
MANIFEST = "PASSWORD DOCUMENT MANIFEST "
MAX_SAMPLES = 4
SAMPLE_BOUND = 2.5
MAX_SAMPLE_BYTES = 4 * 1024 * 1024


def native_runner():
    spec = importlib.util.spec_from_file_location("password_native_runner", ROOT / "scripts/run-native-tests.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(path, 0o600)


def same_identity(claim, observed):
    return (isinstance(claim, dict) and isinstance(observed, dict)
            and all(type(claim.get(k)) is int and claim[k] > 0 for k in ("pid", "start"))
            and isinstance(claim.get("path"), str) and os.path.isabs(claim["path"])
            and isinstance(observed.get("path"), str) and os.path.isabs(observed["path"])
            and all(claim[k] == observed.get(k) for k in ("pid", "start"))
            and os.path.realpath(claim["path"]) == os.path.realpath(observed["path"]))


def authorize_claim(record, role, hosts, identity):
    """Reject PID reuse, executable changes, and any host outside this invocation."""
    ui, claim = record.get("ui"), record.get(role)
    if not any(same_identity(ui, host["host"]) for host in hosts):
        raise ValueError("UI identity is not in this invocation's validated manifest")
    if not same_identity(ui, identity(ui["pid"])):
        raise ValueError("UI launch is no longer current")
    if not isinstance(claim, dict) or type(claim.get("pid")) is not int:
        raise ValueError("missing diagnostic process identity")
    if not same_identity(claim, identity(claim["pid"])):
        raise ValueError("diagnostic process identity changed")
    if role == "content":
        path = os.path.realpath(claim["path"])
        suffix = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        if path not in (suffix, "/System/Volumes/Preboot/Cryptexes/OS" + suffix):
            raise ValueError("content executable is not the system WebKit WebContent")
        if record.get("phase") != "pending":
            raise ValueError("content capture requires a fresh pending WKWebView receipt")
    return claim


def task_counters(pid):
    """Raw proc_taskinfo counters; no inferred CPU percentage or time units."""
    names64 = ("virtual_size", "resident_size", "total_user", "total_system", "threads_user", "threads_system")
    names32 = ("policy", "faults", "pageins", "cow_faults", "messages_sent", "messages_received",
               "syscalls_mach", "syscalls_unix", "csw", "threadnum", "numrunning", "priority")
    class TaskInfo(ctypes.Structure):
        _fields_ = [(key, ctypes.c_uint64) for key in names64] + [(key, ctypes.c_int32) for key in names32]
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    info = TaskInfo()
    size = lib.proc_pidinfo(pid, 4, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info):
        return {"unavailable": True, "errno": ctypes.get_errno()}
    return dict(monotonic=time.monotonic(), **{key: getattr(info, key) for key in names64 + names32})


def capture_process(claim, output, cancelled, identity, counters=task_counters,
                    popen=subprocess.Popen, now=time.monotonic, pause=time.sleep):
    """Only the sampler Popen child may be terminated; never the sampled PID."""
    result = {"claim": claim, "status": "refused"}
    if cancelled.is_set():
        return dict(result, status="cancelled", reason="navigation committed before capture")
    if not same_identity(claim, identity(claim["pid"])):
        return dict(result, reason="identity changed before capture")
    result["before"] = counters(claim["pid"])
    sampler = None
    try:
        console = output.with_suffix(".console.txt")
        with console.open("wb") as stream:
            # An explicit owned report avoids sample's default untracked /tmp copy.
            sampler = popen(["/usr/bin/sample", str(claim["pid"]), "1", "10", "-file", str(output)],
                            stdout=stream, stderr=subprocess.STDOUT)
            deadline = now() + SAMPLE_BOUND
            reason = None
            while sampler.poll() is None:
                if cancelled.is_set(): reason = "navigation committed during capture"
                elif now() >= deadline: reason = "sampler exceeded diagnostic bound"
                elif any(path.exists() and path.stat().st_size > MAX_SAMPLE_BYTES for path in (output, console)):
                    reason = "sample output exceeded diagnostic bound"
                elif not same_identity(claim, identity(claim["pid"])): reason = "sampled identity changed"
                if reason:
                    # An unreaped direct Popen child cannot have its PID reused.
                    sampler.terminate()
                    try: sampler.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        sampler.kill()
                        sampler.wait(timeout=0.5)
                    break
                pause(0.025)
            status = sampler.wait(timeout=0.5)
            if reason is None and (status != 0 or not output.exists() or output.stat().st_size == 0):
                reason = "sampler failed or returned empty evidence"
            result.update(status="cancelled" if cancelled.is_set() else "captured" if reason is None else "incomplete",
                          sampler_exit=status, reason=reason)
        for path in (output, console):
            if path.exists() and path.stat().st_size > MAX_SAMPLE_BYTES:
                with path.open("r+b") as stream: stream.truncate(MAX_SAMPLE_BYTES)
                result["truncated"] = True
        if same_identity(claim, identity(claim["pid"])):
            result["after"] = counters(claim["pid"])
        else:
            result.update(status="incomplete", reason="identity unavailable after capture; stack attribution unverified")
    except Exception as error:
        result.update(status="error", reason=str(error))
        if sampler is not None and sampler.poll() is None:
            sampler.kill()  # This is still our unreaped direct sampler child.
            sampler.wait(timeout=0.5)
    return result


class Collector:
    """Bounded diagnostics scheduled independently of XCTest's original deadline."""
    def __init__(self, evidence, runner=None, capture=capture_process):
        self.evidence = evidence
        self.runner = runner or native_runner()
        self.capture = capture
        self.manifest = None
        self.pending = {}
        self.committed = set()
        self.jobs = []
        self.events = []
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)

    def line(self, line, now=None):
        now = time.monotonic() if now is None else now
        if len(line) > 16384: return
        try:
            if line.startswith(MANIFEST):
                path = Path(line[len(MANIFEST):].strip())
                contract = self.runner.read_private_json(path / "contract.json")
                self.runner.load_records(path, contract["token"])
                self.manifest = (path, contract["token"])
            elif line.startswith(COMMIT):
                token = line[len(COMMIT):].strip()
                self.committed.add(token)
                if token in self.pending: self.pending[token]["cancel"].set()
            elif line.startswith(PROCESS):
                value = json.loads(line[len(PROCESS):])
                token = value.get("token")
                if value.get("path") != "password" or not isinstance(token, str) or len(token) > 64: return
                if len(self.pending) >= 32 and token not in self.pending: return
                entry = self.pending.setdefault(token, {"first": now, "cancel": threading.Event(), "scheduled": set()})
                entry[value.get("phase", "unknown")] = (now, value)
                if token in self.committed: entry["cancel"].set()
        except (ValueError, KeyError, OSError, TypeError) as error:
            self.events.append({"status": "refused", "reason": str(error)})

    def tick(self, now=None):
        now = time.monotonic() if now is None else now
        if not self.manifest or len(self.jobs) >= MAX_SAMPLES: return
        for token, entry in self.pending.items():
            if entry["cancel"].is_set() or now - entry["first"] < 0.75: continue
            for role in ("ui", "content"):
                if role in entry["scheduled"] or len(self.jobs) >= MAX_SAMPLES: continue
                receipt = entry.get("pending") if role == "content" else entry.get("before-load")
                if receipt is None: continue
                if role == "content" and now - receipt[0] > 0.5:
                    entry["scheduled"].add(role)
                    self.events.append({"token": token, "role": role, "status": "refused", "reason": "pending content receipt is stale"})
                    continue
                entry["scheduled"].add(role)
                try:
                    hosts = self.runner.load_records(*self.manifest)
                    claim = authorize_claim(receipt[1], role, hosts, self.runner.process_identity)
                    output = self.evidence / ("sample-%02d-%s.txt" % (len(self.jobs), role))
                    future = self.pool.submit(self.capture, claim, output, entry["cancel"], self.runner.process_identity)
                    self.jobs.append((token, role, output.name, future))
                except (ValueError, OSError, KeyError) as error:
                    self.events.append({"token": token, "role": role, "status": "refused", "reason": str(error)})

    def finish(self):
        for entry in self.pending.values(): entry["cancel"].set()
        self.pool.shutdown(wait=True, cancel_futures=False)
        for token, role, output, future in self.jobs:
            try: result = future.result()
            except Exception as error: result = {"status": "error", "reason": str(error)}
            self.events.append(dict(token=token, role=role, output=output, **result))
        return self.events

    def report(self):
        events = self.finish()
        return {"events": events, "password_load_receipts": len(self.pending),
                "valid": bool(self.pending) and all(event["status"] in ("captured", "cancelled") for event in events)}


def runner_child(evidence, arguments):
    """Keep the canonical native cleanup protocol; archive only its own directory."""
    runner = native_runner()
    original_mkdtemp, original_rmtree = runner.tempfile.mkdtemp, runner.shutil.rmtree
    directory = None
    def announce(*args, **kwargs):
        nonlocal directory
        path = original_mkdtemp(*args, **kwargs)
        directory = Path(path).resolve()
        return path
    def archive(path, *args, **kwargs):
        if directory is not None and Path(path).resolve() == directory:
            snapshot()
        return original_rmtree(path, *args, **kwargs)
    def snapshot():
        if directory is None or not directory.exists(): return
        contract = runner.read_private_json(directory / "contract.json")
        records = runner.load_records(directory, contract["token"])
        cleanup = directory / "cleanup-host.json"
        if cleanup.exists(): records.append(runner.validate_record(runner.read_private_json(cleanup), contract["token"]))
        observations = []
        for record in records:
            host = record["host"]
            observed = runner.process_identity(host["pid"])
            observations.append({"host": host, "observed": observed,
                                 "ownedLaunchExited": observed is None or observed["start"] != host["start"]})
        destination = evidence / "retirement"
        if not destination.exists(): shutil.copytree(directory, destination)
        write_json(evidence / "ownership.json", {"hosts": observations, "allExited": all(row["ownedLaunchExited"] for row in observations)})
    # Contract is written after mkdtemp. Announce immediately before the first
    # driver launches, when contract and private directory can be validated.
    original_popen = runner.subprocess.Popen
    announced = False
    def launch(*args, **kwargs):
        nonlocal announced
        if not announced:
            print(MANIFEST + str(directory), flush=True)
            announced = True
        return original_popen(*args, **kwargs)
    runner.tempfile.mkdtemp, runner.shutil.rmtree, runner.subprocess.Popen = announce, archive, launch
    try:
        return runner.main(arguments)
    finally:
        snapshot()


def verify_execution(log, expected, allowed_skips, expected_order_hash=None):
    """Zero exit alone does not prove the frozen XCTest selection ran."""
    primary = log.split("NATIVE TEST DRIVER", 1)[-1].split("phase=cleanup", 1)[0]
    events = re.findall(r"Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|failed|skipped)", primary)
    started, outcomes = [], {}
    for suite, case, outcome in events:
        name = suite + "/" + case
        if outcome == "started": started.append(name)
        else: outcomes.setdefault(name, []).append(outcome)
    problems = []
    expected = set(expected)
    if len(started) != len(expected) or set(started) != expected:
        problems.append("selected XCTest starts differ from the frozen selection")
    observed_order_hash = hashlib.sha256(json.dumps(started, separators=(",", ":")).encode()).hexdigest()
    if expected_order_hash is not None and observed_order_hash != expected_order_hash:
        problems.append("XCTest execution order differs from the original pressure sequence")
    for name in expected:
        result = outcomes.get(name, [])
        if len(result) != 1 or result[0] not in ("passed", "skipped"):
            problems.append("missing/duplicate/failed outcome: " + name)
        elif result[0] == "skipped" and name not in allowed_skips:
            problems.append("new/unapproved skip: " + name)
    if set(outcomes) - expected: problems.append("unexpected XCTest outcomes")
    if outcomes.get(TARGET) != ["passed"]: problems.append("target did not execute and pass exactly once")
    if re.search(r"(?im)Backtrace took|Program crashed|Fatal error:|Signal \d+|error: Exited with unexpected signal|Stack dump:", log):
        problems.append("fatal Swift/process diagnostic appeared")
    return {"valid": not problems, "problems": problems, "starts": len(started), "order_sha256": observed_order_hash,
            "outcomes": outcomes, "preserved_original_skips": sorted(name for name, values in outcomes.items() if values == ["skipped"] and name in allowed_skips)}


def run_attempt(evidence, control, tests, allowed_skips, expected_order_hash):
    evidence.mkdir(mode=0o700)
    selection = "^(?:" + "|".join(re.escape(test) for test in tests) + ")$"
    arguments = ["--build-system", "native", "--skip-build", "--jobs", "1", "--filter", selection]
    environment = dict(os.environ, VANE_PASSWORD_DOCUMENT_CONTROL=control, PYTHONDONTWRITEBYTECODE="1")
    environment.setdefault("VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT", "900")
    write_json(evidence / "invocation.json", {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "arguments": arguments, "control": control, "diagnostic_only": True})
    collector = Collector(evidence)
    command = [sys.executable, "-u", __file__, "--runner-child", str(evidence), "--", *arguments]
    child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    lines = queue.Queue(maxsize=256)
    def reader():
        try:
            for raw in child.stdout: lines.put(raw)
        finally: lines.put(None)
    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    with (evidence / "native.log").open("wb") as log:
        complete = False
        while not complete:
            try: raw = lines.get(timeout=0.025)
            except queue.Empty: raw = b""
            if raw is None: complete = True
            elif raw:
                log.write(raw)
                log.flush()
                line = raw.decode("utf-8", errors="replace")
                sys.stdout.write(line)
                sys.stdout.flush()
                collector.line(line)
            collector.tick()
    thread.join(timeout=1)
    status = child.wait()
    execution = verify_execution((evidence / "native.log").read_text(errors="replace"), tests, allowed_skips, expected_order_hash)
    write_json(evidence / "execution.json", execution)
    diagnostics = collector.report()
    write_json(evidence / "diagnostics.json", dict(diagnostics, native_exit=status,
               diagnostic_only=True, interpretation="No sample or passing retry establishes a repair."))
    return {"native_exit": status, "execution_valid": execution["valid"], "diagnostics_valid": diagnostics["valid"]}


def plan(inventory, config):
    value = json.loads(config.read_text())
    if (value.get("schema") != 1 or value.get("diagnostic_only") is not True or value.get("target") != TARGET
            or len(value.get("prefix", [])) != 414 or value["prefix"][-1] != TARGET
            or len(set(value["prefix"])) != 414):
        raise ValueError("diagnostic control config does not match the preserved original prefix")
    current = set(inventory.read_text().splitlines())
    missing = set(value["prefix"]) - current
    if missing: raise ValueError("original diagnostic prefix missing from current inventory: " + repr(sorted(missing)))
    expected = [("original-prefix", "trace", 1, "prefix"), ("original-direct", "trace", 3, "target"),
                ("held-discovery-direct", "held-discovery", 3, "target")]
    if [(v.get("name"), v.get("control"), v.get("repetitions"), v.get("selection")) for v in value.get("vectors", [])] != expected:
        raise ValueError("diagnostic repetitions/vector order changed")
    return value


def main(arguments):
    if arguments and arguments[0] == "--runner-child":
        return runner_child(Path(arguments[1]), arguments[3:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--calibration", choices=("trace", "held-discovery"), help="one local direct diagnostic; never acceptance")
    options = parser.parse_args(arguments)
    config = ROOT / "scripts/password-document-preflight.json"
    value = plan(options.inventory, config)
    options.evidence = options.evidence.resolve()
    options.evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    shutil.copyfile(config, options.evidence / "controls.json")
    shutil.copyfile(options.inventory, options.evidence / "inventory.txt")
    (options.evidence / "source.diff").write_bytes(subprocess.check_output(["git", "diff"], cwd=ROOT))
    attempts = []
    vectors = value["vectors"] if options.calibration is None else [{"name": "calibration", "control": options.calibration, "selection": "target", "repetitions": 1}]
    for vector in vectors:
        tests = value["prefix"] if vector["selection"] == "prefix" else [TARGET]
        expected_order_hash = value["original_prefix_order_sha256"] if vector["selection"] == "prefix" else hashlib.sha256(json.dumps(tests, separators=(",", ":")).encode()).hexdigest()
        for index in range(vector["repetitions"]):
            label = vector["name"] + "-" + str(index + 1)
            result = run_attempt(options.evidence / label, vector["control"], tests, set(value["original_prefix_skips"]), expected_order_hash)
            attempts.append(dict(label=label, **result))
            write_json(options.evidence / "summary.json", {"diagnostic_only": True, "attempts": attempts})
            ownership_path = options.evidence / label / "ownership.json"
            if not ownership_path.exists() or not json.loads(ownership_path.read_text()).get("allExited"):
                print("Diagnostic cohort stopped: native host exit is unverified", file=sys.stderr)
                return 2
    return 1 if any(attempt["native_exit"] or not attempt["execution_valid"] or not attempt["diagnostics_valid"] for attempt in attempts) else 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main(sys.argv[1:]))
