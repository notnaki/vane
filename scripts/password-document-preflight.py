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
import uuid

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


def phase_module():
    spec = importlib.util.spec_from_file_location("password_phase_channel", ROOT / "scripts/password-document-phases.py")
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
                    popen=subprocess.Popen, now=time.monotonic, pause=time.sleep, progress=None):
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
        with console.open("w+b") as stream:
            # An explicit owned report avoids sample's default untracked /tmp copy.
            sampler = popen(["/usr/bin/sample", str(claim["pid"]), "1", "10", "-file", str(output)],
                            stdout=stream, stderr=subprocess.STDOUT)
            result.update(sampler_pid=getattr(sampler, 'pid', None), capture_started_monotonic_ns=time.monotonic_ns(),
                          target_live_at_start=same_identity(claim, identity(claim['pid'])))
            if type(result['sampler_pid']) is int:
                result['sampler_identity'] = identity(result['sampler_pid'])
            deadline = now() + SAMPLE_BOUND
            reason = None
            while sampler.poll() is None:
                if 'sample_progress_monotonic_ns' not in result:
                    progress_output = os.pread(stream.fileno(), 4096, 0)
                    if ('Sampling process ' + str(claim['pid']) + ' for ').encode() in progress_output:
                        result.update(sample_progress_monotonic_ns=time.monotonic_ns(),
                                      target_live_at_sample_progress=same_identity(claim, identity(claim['pid'])))
                        if progress is not None:
                            child = result.get('sampler_identity')
                            if (not result['target_live_at_sample_progress'] or not isinstance(child, dict)
                                    or not same_identity(child, identity(child['pid']))
                                    or os.path.realpath(child['path']) != os.path.realpath('/usr/bin/sample')):
                                raise ValueError('live sampler progress identity was unavailable')
                            progress({key: result[key] for key in ('claim', 'sampler_identity',
                                'capture_started_monotonic_ns', 'sample_progress_monotonic_ns',
                                'target_live_at_start', 'target_live_at_sample_progress')})
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
    def __init__(self, evidence, runner=None, capture=capture_process, acknowledge=None, channel_token=None):
        self.evidence = evidence
        self.runner = runner or native_runner()
        self.capture = capture
        self.manifest = None
        self.pending = {}
        self.committed = set()
        self.jobs = []
        self.events = []
        self.acknowledge, self.channel_token = acknowledge, channel_token
        self.progress = queue.Queue(maxsize=MAX_SAMPLES)
        self.acknowledgments = []
        self.calibration_holds = {}
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
        self.acknowledge_progress()
        if not self.manifest or len(self.jobs) >= MAX_SAMPLES: return
        for token, entry in self.pending.items():
            if entry["cancel"].is_set() or now - entry["first"] < 0.75: continue
            if self.acknowledge is not None and token not in self.calibration_holds: continue
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
                    kwargs = {}
                    if self.acknowledge is not None:
                        def progress(value, token=token, role=role):
                            self.progress.put_nowait((token, role, value))
                        kwargs['progress'] = progress
                    future = self.pool.submit(self.capture, claim, output, entry["cancel"], self.runner.process_identity, **kwargs)
                    self.jobs.append((token, role, output.name, future))
                except (ValueError, OSError, KeyError) as error:
                    self.events.append({"token": token, "role": role, "status": "refused", "reason": str(error)})

    def calibration_hold(self, token, stamp):
        if self.acknowledge is None: return
        if (not isinstance(token, str) or not 0 < len(token) <= 64 or type(stamp) is not int or stamp <= 0
                or token in self.calibration_holds or len(self.calibration_holds) >= 32):
            raise ValueError('invalid or duplicate genuine calibration hold')
        self.calibration_holds[token] = stamp

    def acknowledge_progress(self):
        if self.acknowledge is None: return
        for _ in range(MAX_SAMPLES):
            try: token, role, value = self.progress.get_nowait()
            except queue.Empty: break
            try:
                entry = self.pending[token]
                if role not in ('ui', 'content') or role not in entry['scheduled'] or entry['cancel'].is_set():
                    raise ValueError('sampler progress is not from an active scheduled role')
                rows = entry.setdefault('progress', {})
                if role in rows: raise ValueError('duplicate sampler progress role')
                rows[role] = value
                if set(rows) != {'ui', 'content'} or entry.get('acknowledged'): continue
                hosts = self.runner.load_records(*self.manifest)
                samples = []
                now_ns = time.monotonic_ns()
                held_ns = self.calibration_holds[token]
                if (not re.fullmatch('[a-f0-9]{32}', self.channel_token or '')
                        or not re.fullmatch('[a-f0-9]{32}', self.manifest[1])):
                    raise ValueError('sampler acknowledgment contract tokens are invalid')
                for name in ('ui', 'content'):
                    row = rows[name]
                    record = entry['pending' if name == 'content' else 'before-load'][1]
                    target = authorize_claim(record, name, hosts, self.runner.process_identity)
                    sampler = row.get('sampler_identity')
                    begin, stamp = row.get('capture_started_monotonic_ns'), row.get('sample_progress_monotonic_ns')
                    if (not same_identity(row.get('claim'), target)
                            or row.get('target_live_at_start') is not True
                            or row.get('target_live_at_sample_progress') is not True
                            or not isinstance(sampler, dict)
                            or not same_identity(sampler, self.runner.process_identity(sampler['pid']))
                            or os.path.realpath(sampler['path']) != os.path.realpath('/usr/bin/sample')
                            or type(begin) is not int or type(stamp) is not int
                            or not 0 < held_ns <= begin <= stamp <= now_ns or now_ns - stamp > 500_000_000):
                        raise ValueError('sampler progress identities or freshness changed before acknowledgment')
                    samples.append({'role': name, 'target': target, 'sampler': sampler,
                                    'captureStartedMonotonicNs': begin, 'progressMonotonicNs': stamp})
                if len({r['sampler']['pid'] for r in samples}) != 2:
                    raise ValueError('sampler progress does not have two distinct children')
                issued_ns = time.monotonic_ns()
                if any(issued_ns - r['progressMonotonicNs'] > 500_000_000 for r in samples):
                    raise ValueError('sampler progress became stale during identity validation')
                proof = {'schema': 1, 'channelToken': self.channel_token, 'nativeToken': self.manifest[1],
                         'navigationToken': token, 'issuedMonotonicNs': issued_ns, 'samples': samples}
                self.acknowledge(proof)
                entry['acknowledged'] = True
                self.acknowledgments.append(proof)
            except (ValueError, OSError, KeyError, TypeError) as error:
                self.events.append({'token': token, 'role': role, 'status': 'refused', 'reason': str(error)})

    def finish(self):
        for token, entry in self.pending.items():
            entry["cancel"].set()
            if 'ui' in entry['scheduled'] and 'content' not in entry['scheduled']:
                reason = ('fresh pending content receipt was unavailable after UI sampling became necessary'
                          if 'pending' not in entry else 'bounded content sampling capacity was unavailable')
                self.events.append({'token': token, 'role': 'content', 'status': 'incomplete', 'reason': reason})
                entry['scheduled'].add('content')
        self.pool.shutdown(wait=True, cancel_futures=False)
        for token, role, output, future in self.jobs:
            try: result = future.result()
            except Exception as error: result = {"status": "error", "reason": str(error)}
            self.events.append(dict(token=token, role=role, output=output, **result))
        return self.events

    def report(self):
        events = self.finish()
        return {"events": events, "password_load_receipts": len(self.pending),
                'sampler_acknowledgments': self.acknowledgments,
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
            phase_directory = os.environ.get('VANE_PASSWORD_PHASE_DIRECTORY')
            channel_token = os.environ.get('VANE_PASSWORD_PHASE_TOKEN')
            if not phase_directory or not channel_token: raise ValueError('missing direct phase channel contract')
            contract = runner.read_private_json(directory / 'contract.json')
            phase_module().publish_private(Path(phase_directory), 'context.json',
                {'schema': 1, 'channelToken': channel_token, 'nativeDirectory': str(directory), 'nativeToken': contract['token']})
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


def verify_pending_calibration(channel, samples):
    events = [row['source'] for row in channel['events']]
    def one(phase):
        rows = [r for r in events if r['phase'] == phase]
        return rows[0] if len(rows) == 1 else None
    start, held, accepted, released = (one(name) for name in
        ('calibration-start', 'calibration-held', 'calibration-acknowledged', 'calibration-released'))
    commits = [r for r in events if r['phase'] == 'commit' and r['fields'].get('path') == 'password']
    loads = [r for r in events if r['phase'] == 'load-entry' and r['fields'].get('path') == 'password']
    if not all((start, held, accepted, released)) or len(commits) != 1 or len(loads) != 1:
        return {'valid': False, 'problems': ['missing/duplicate real calibration, acknowledgment or navigation receipts']}
    problems = []
    begin, end = held['monotonicNs'], released['monotonicNs']
    budget_start = start['fields'].get('startedMonotonicNs')
    deadline = start['fields'].get('deadlineMonotonicNs')
    if (type(deadline) is not int or type(budget_start) is not int or deadline - budget_start != 3_000_000_000
            or not budget_start <= start['monotonicNs'] <= begin <= accepted['monotonicNs'] < end < deadline
            or commits[0]['monotonicNs'] < end or any(r['phase'] == 'calibration-failed' for r in events)):
        problems.append('calibration did not release acknowledged progress inside its absolute3s budget')
    proof = accepted['fields'].get('proof', {})
    token = loads[0]['fields'].get('token')
    issued = proof.get('issuedMonotonicNs') if isinstance(proof, dict) else None
    if (not isinstance(proof, dict) or type(proof.get('schema')) is not int or proof['schema'] != 1
            or proof.get('channelToken') != accepted.get('channelToken')
            or proof.get('nativeToken') != accepted.get('nativeToken')
            or proof.get('navigationToken') != token or held['fields'].get('token') != token
            or type(issued) is not int or not begin <= issued <= accepted['monotonicNs']
            or accepted['monotonicNs'] - issued > 500_000_000):
        return {'valid': False, 'problems': problems + ['accepted acknowledgment token or lifetime mismatch']}
    rows = proof.get('samples', [])
    if len(rows) != 2 or sorted(r.get('role', '') for r in rows) != ['content', 'ui']:
        return {'valid': False, 'problems': problems + ['accepted acknowledgment needs both exact sampler roles']}
    verified = []
    for role in ('ui', 'content'):
        actual = [r for r in samples if r.get('role') == role]
        claimed = next(r for r in rows if r['role'] == role)
        if len(actual) != 1:
            problems.append('missing/duplicate actual sampler role: ' + role)
            continue
        row = actual[0]
        child = row.get('sampler_identity')
        capture, progress = row.get('capture_started_monotonic_ns'), row.get('sample_progress_monotonic_ns')
        if (not same_identity(child, claimed.get('sampler')) or child.get('pid') != row.get('sampler_pid')
                or os.path.realpath(child['path']) != os.path.realpath('/usr/bin/sample')
                or not same_identity(row.get('claim'), claimed.get('target'))
                or row.get('target_live_at_start') is not True or row.get('target_live_at_sample_progress') is not True
                or type(capture) is not int or type(progress) is not int
                or not begin <= capture <= progress <= issued < end
                or claimed.get('captureStartedMonotonicNs') != capture or claimed.get('progressMonotonicNs') != progress
                or row.get('status') not in ('captured', 'cancelled')):
            problems.append('actual live sampling progress differs from accepted proof: ' + role)
        else: verified.append(role)
    return {'valid': not problems, 'problems': problems, 'holdMonotonicNs': end - begin,
            'samplersStartedWhilePending': len(verified), 'verifiedRoles': verified,
            'totalBudgetMonotonicNs': deadline - budget_start if type(deadline) is int and type(budget_start) is int else None}


def verify_script_provenance(channel, control):
    source = [row.get('source', {}) for row in channel.get('events', []) if isinstance(row, dict)]
    records = [row.get('fields', {}) for row in source if row.get('phase') == 'script-provenance']
    breadcrumbs = sum(row.get('phase') == 'password-native' and
                      str(row.get('fields', {}).get('stage', '')).startswith('javascript-') for row in source)
    if len(records) != 1:
        return {'valid': False, 'problems': ['missing or duplicate installed-script provenance'], 'mode': control}
    fields = records[0]
    problems = []
    if fields.get('mode') != control: problems.append('script provenance control differs from declared arm')
    for key in ('productionSHA256', 'installedSHA256'):
        if not isinstance(fields.get(key), str) or not re.fullmatch('[a-f0-9]{64}', fields[key]):
            problems.append('missing SHA256 script fingerprint: ' + key)
    if (type(fields.get('matchingInstalledScripts')) is not int or fields['matchingInstalledScripts'] != 1
            or fields.get('mainFrameOnly') is not True
            or type(fields.get('injectionTime')) is not int or fields['injectionTime'] != 1
            or any(type(fields.get(key)) is not int or fields[key] <= 0 for key in ('productionBytes', 'installedBytes'))):
        problems.append('actual installed script does not match the single main-frame document-end resource')
    native_only = control == 'native-only'
    equal = fields.get('productionSHA256') == fields.get('installedSHA256')
    if native_only:
        if (fields.get('byteExactProduction') is not True or not equal
                or fields.get('productionBytes') != fields.get('installedBytes')):
            problems.append('native-only installed script is not byte-identical to the production resource')
        if breadcrumbs: problems.append('native-only unexpectedly emitted ancestry instrumentation')
    elif fields.get('byteExactProduction') is not False or equal or not breadcrumbs:
        problems.append('trace arm lacks distinct rewritten bytes or actual ancestry receipts')
    return {'valid': not problems, 'problems': problems, 'mode': control, 'installed': fields,
            'ancestryBreadcrumbs': breadcrumbs, 'ancestryAbsenceExpected': native_only}


def verify_username_step_receipt(channel):
    source = [row.get('source', {}) for row in channel.get('events', []) if isinstance(row, dict)]
    loads = [row for row in source if row.get('phase') == 'load-entry' and row.get('fields', {}).get('path') == 'password']
    receipts = [row for row in source if row.get('phase') == 'password-native'
                and row.get('fields', {}).get('stage') == 'main-username-step']
    chosen = [row for row in source if row.get('phase') == 'password-native'
              and row.get('fields', {}).get('stage') == 'chosen-applied']
    if len(loads) != 1:
        return {'valid': False, 'classification': 'incomplete-load-receipt', 'messageAdmittedBeforeLoad': False,
                'allObservedContinuationAllowedFalse': False, 'receipts': []}
    load = loads[0]['monotonicNs']
    admitted = bool(receipts) and all(row['monotonicNs'] < load for row in receipts)
    selected_documents = {row['fields']['document'] for row in chosen if isinstance(row['fields'].get('document'), str)}
    selection_before_load = bool(chosen) and all(row['monotonicNs'] < load for row in chosen)
    documents_complete = all(isinstance(row['fields'].get('document'), str) and row['fields']['document'] for row in chosen)
    outgoing = next(iter(selected_documents)) if documents_complete and len(selected_documents) == 1 else None
    document_matches = bool(outgoing) and bool(receipts) and all(row['fields'].get('document') == outgoing for row in receipts)
    denied = bool(receipts) and all(row['fields'].get('continuationAllowed') is False for row in receipts)
    classification = ('incomplete-main-message-admission' if not admitted else
                      'incomplete-outgoing-document-attribution' if not selection_before_load or not document_matches else
                      'continuation-decision-mismatch' if not denied else 'fully-admitted-negative')
    return {'valid': admitted and denied and selection_before_load and document_matches, 'classification': classification,
            'messageAdmittedBeforeLoad': admitted, 'allObservedContinuationAllowedFalse': denied,
            'anyMessageAdmittedBeforeLoad': any(row['monotonicNs'] < load for row in receipts),
            'postLoadReceiptCount': sum(row['monotonicNs'] >= load for row in receipts),
            'selectionRecordedBeforeLoad': selection_before_load, 'outgoingSelectionDocument': outgoing,
            'mainReceiptsMatchOutgoingDocument': document_matches,
            'receipts': [{'secondsRelativeToLoad': (row['monotonicNs'] - load) / 1e9,
                          'continuationAllowed': row['fields'].get('continuationAllowed'),
                          'document': row['fields'].get('document')} for row in receipts]}


def verify_comparison_provenance(attempts):
    expected = ('native-only', 'trace', 'pending-calibration')
    proofs = [row.get('script_provenance', {}) for row in attempts]
    problems = []
    if len(proofs) != 3 or tuple(row.get('mode') for row in proofs) != expected:
        return {'valid': False, 'problems': ['missing or out-of-order declared comparison arms']}
    if not all(row.get('valid') for row in proofs): problems.append('an arm lacks valid installed-script provenance')
    installed = [row.get('installed', {}) for row in proofs]
    production = [row.get('productionSHA256') for row in installed]
    if not production[0] or len(set(production)) != 1: problems.append('production resource differs between arms')
    if (installed[0].get('installedSHA256') != production[0]
            or installed[1].get('installedSHA256') != installed[2].get('installedSHA256')
            or installed[1].get('installedSHA256') == production[0]):
        problems.append('comparison did not isolate exact production bytes versus the same ancestry rewrite')
    return {'valid': not problems, 'problems': problems, 'productionSHA256': production[0],
            'nativeOnlySHA256': installed[0].get('installedSHA256'),
            'ancestryTraceSHA256': installed[1].get('installedSHA256')}


def run_attempt(evidence, control, tests, allowed_skips, expected_order_hash):
    evidence.mkdir(mode=0o700)
    phase_directory = evidence / 'phase-channel'
    phase_directory.mkdir(mode=0o700)
    channel_token = uuid.uuid4().hex
    selection = "^(?:" + "|".join(re.escape(test) for test in tests) + ")$"
    arguments = ["--build-system", "native", "--skip-build", "--jobs", "1", "--filter", selection]
    environment = dict(os.environ, VANE_PASSWORD_DOCUMENT_CONTROL=control, PYTHONDONTWRITEBYTECODE="1",
                       VANE_PASSWORD_PHASE_DIRECTORY=str(phase_directory), VANE_PASSWORD_PHASE_TOKEN=channel_token)
    environment.setdefault("VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT", "900")
    write_json(evidence / "invocation.json", {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "arguments": arguments, "control": control, "diagnostic_only": True})
    acknowledge = ((lambda proof: phase_module().publish_private(phase_directory, 'samplers-ready.json', proof))
                   if control == 'pending-calibration' else None)
    collector = Collector(evidence, acknowledge=acknowledge, channel_token=channel_token)
    phases = phase_module().PhaseReader(phase_directory, channel_token, collector.runner, collector)
    print('PASSWORD DIAGNOSTIC ATTEMPT started: ' + evidence.name, flush=True)
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
            phases.poll()
            collector.tick()
            try: raw = lines.get(timeout=0.025)
            except queue.Empty: raw = b""
            if raw is None: complete = True
            elif raw:
                log.write(raw)
                log.flush()
                # Keep stdout replay/backpressure out of the live observation path.
    thread.join(timeout=1)
    status = child.wait()
    phases.poll()
    execution = verify_execution((evidence / "native.log").read_text(errors="replace"), tests, allowed_skips, expected_order_hash)
    write_json(evidence / "execution.json", execution)
    diagnostics = collector.report()
    channel = phases.report()
    phases.close()
    diagnostics['phase_channel'] = channel
    diagnostics['valid'] = diagnostics['valid'] and channel['valid']
    script = verify_script_provenance(channel, control)
    admission = verify_username_step_receipt(channel)
    diagnostics['script_provenance'] = script
    diagnostics['username_admission'] = admission
    diagnostics['valid'] = diagnostics['valid'] and script['valid'] and admission['valid']
    if control == 'pending-calibration':
        calibration = verify_pending_calibration(channel, diagnostics['events'])
        diagnostics['pending_calibration'] = calibration
        diagnostics['valid'] = diagnostics['valid'] and calibration['valid']
    write_json(evidence / "diagnostics.json", dict(diagnostics, native_exit=status,
               diagnostic_only=True, interpretation="No sample or passing retry establishes a repair."))
    print('PASSWORD DIAGNOSTIC ATTEMPT completed: ' + evidence.name + ' native=' + str(status)
          + ' execution=' + str(execution['valid']) + ' telemetry=' + str(diagnostics['valid']), flush=True)
    return {"native_exit": status, "execution_valid": execution["valid"], "diagnostics_valid": diagnostics["valid"],
            'script_provenance': script, 'username_admission': admission}


def plan(inventory, config):
    value = json.loads(config.read_text())
    if (value.get("schema") != 1 or value.get("diagnostic_only") is not True or value.get("target") != TARGET
            or len(value.get("prefix", [])) != 414 or value["prefix"][-1] != TARGET
            or len(set(value["prefix"])) != 414):
        raise ValueError("diagnostic control config does not match the preserved original prefix")
    current = set(inventory.read_text().splitlines())
    missing = set(value["prefix"]) - current
    if missing: raise ValueError("original diagnostic prefix missing from current inventory: " + repr(sorted(missing)))
    expected = [("pending-sampler-acknowledgment", "pending-calibration", 1, "target")]
    if value.get('stage') != 'sampler-readiness' or value.get('qualified_comparison_run') != 40948827683:
        raise ValueError('sampler readiness must retain the separately qualified script comparison')
    if [(v.get("name"), v.get("control"), v.get("repetitions"), v.get("selection")) for v in value.get("vectors", [])] != expected:
        raise ValueError("diagnostic repetitions/vector order changed")
    return value


def main(arguments):
    if arguments and arguments[0] == "--runner-child":
        return runner_child(Path(arguments[1]), arguments[3:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--calibration", choices=("trace", "native-only", "held-discovery", "pending-calibration"), help="one local direct diagnostic; never acceptance")
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
    comparison = {'valid': True, 'applicable': False,
                  'reason': 'single sampler readiness calibration; previous script comparison is retained separately',
                  'qualified_comparison_run': value['qualified_comparison_run']}
    write_json(options.evidence / "summary.json", {"diagnostic_only": True, "attempts": attempts,
               'script_comparison': comparison})
    return 1 if not comparison['valid'] or any(attempt["native_exit"] or not attempt["execution_valid"] or not attempt["diagnostics_valid"] for attempt in attempts) else 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main(sys.argv[1:]))
