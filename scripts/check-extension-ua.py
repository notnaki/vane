#!/usr/bin/env python3
"""Diagnostic-only signed normal-app UA comparison, extracted from reviewed PR503.

Actual Vane production code paths, eight fresh ad-hoc sandbox launches.
Not a release-signing/notarization check or third-party extension acceptance.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import signal
import stat
import time
from datetime import datetime
import uuid

TEAM_ID = "T7X84HN3W3"
UA_LABELS = ("UA normal-loop host", "UA normal-loop safari-mv2", "UA normal-loop safari-mv3",
             "UA normal-loop custom-mv3", "UA normal-loop safari-after-custom-mv3")
UA_OUTPUT_LIMIT = 1024 * 1024
UA_OBSERVER_MODES = ("registered", "unregistered")


def validate_observer_mode(mode):
    if mode not in UA_OBSERVER_MODES: raise ValueError("observer mode must be registered or unregistered")
    return mode


def validate_ua_observer(output, expected_mode):
    """Attest the selected diagnostic branch, never worker UA correctness/injection."""
    validate_observer_mode(expected_mode)
    lines = re.findall(rb"(?m)^UA OBSERVER CONFIG[^\r\n]*\r?$", output)
    if len(lines) != 1: raise ValueError("UA observer branch attestation is missing or duplicated")
    match = re.fullmatch(rb"UA OBSERVER CONFIG mode=(registered|unregistered) runNonce=([0-9A-Fa-f-]{36}) scriptRegistered=(true|false)\r?", lines[0])
    if match is None: raise ValueError("UA observer branch attestation is malformed")
    mode, nonce, registered = (value.decode("ascii") for value in match.groups())
    try: uuid.UUID(nonce)
    except ValueError: raise ValueError("UA observer run nonce is invalid") from None
    if mode != expected_mode or (registered == "true") != (expected_mode == "registered"):
        raise ValueError("UA observer branch did not match the requested arm")
    return {"observerMode": mode, "runNonce": nonce, "scriptRegistered": registered == "true"}


class ObserverModeArgument(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        if getattr(namespace, self.dest, None) is not None:
            parser.error("--observer-mode must be specified exactly once")
        setattr(namespace, self.dest, values)


def ua_argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--evidence-dir', type=Path, required=True, help='fresh log-only directory outside disposable app/profile paths')
    parser.add_argument('--observer-mode', choices=UA_OBSERVER_MODES, action=ObserverModeArgument, required=True,
                        help='explicit registered/unregistered loader-script comparison arm; both-success is inconclusive')
    return parser


def validate_ua_report(path, echo_verified=False):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 65_536:
                raise ValueError("UA report must be an owned regular file of at most 64 KiB")
            data = os.read(descriptor, 65_537)
            if len(data) > 65_536: raise ValueError("UA report exceeded 64 KiB")
            report = json.loads(data)
        finally: os.close(descriptor)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("UA report is missing, unsafe, or invalid") from error
    if not isinstance(report, dict) or set(report) != {"profileID", "findings"}:
        raise ValueError("UA report schema did not match")
    try: uuid.UUID(report["profileID"])
    except (ValueError, TypeError, AttributeError): raise ValueError("UA profile UUID is invalid") from None
    findings = report["findings"]
    if not isinstance(findings, list) or len(findings) != len(UA_LABELS):
        raise ValueError("UA report must contain exactly five required stages")
    labels = []
    for finding in findings:
        if not isinstance(finding, dict) or set(finding) != {"workflow", "result", "detail"}:
            raise ValueError("UA finding schema did not match")
        if finding["result"] != "VERIFIED" or not isinstance(finding["detail"], str) or len(finding["detail"].encode()) > 8192:
            raise ValueError("UA stage failed, was unavailable, or has invalid detail")
        labels.append(finding["workflow"])
        if finding["workflow"] == UA_LABELS[0]:
            host = re.fullmatch(r"finishedLaunching=true; appRunning=true; WebKit=([^\r\n;]{1,160}); OS=[^\r\n]{1,160}", finding["detail"])
            if host is None or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*\+?", host.group(1)):
                raise ValueError("UA normal application-loop attestation needs a concrete WebKit version")
    if any(not isinstance(label, str) for label in labels) or sorted(labels) != sorted(UA_LABELS):
        raise ValueError("UA stages were missing, duplicated, or unknown")
    if echo_verified:
        # All five records are validated before any positive evidence is emitted.
        # Each detail is already bounded to 8192 UTF-8 bytes; JSON escaping keeps
        # quotes, control characters and Unicode within one bounded ASCII line.
        for finding in findings: print(json.dumps(finding, ensure_ascii=True, sort_keys=True), flush=True)
    return report["profileID"]


def validate_ua_cleanup(output):
    matches = re.findall(rb"(?m)^PASS browsercheck cleanup: ([1-9][0-9]*) temporary WebKit stores unregistered\r?$", output)
    if len(matches) != 1: raise ValueError("UA post-exit store retirement was not positively verified")


def stop_ua_launch(host, process, identity, send, pause, now):
    for signum in (signal.SIGTERM, signal.SIGKILL):
        if process.poll() is not None: return
        observed = identity(host["pid"])
        if observed != host:
            raise ValueError(f"owned launch changed or cannot be verified; no signal sent: {host}")
        print(f"UA OWNED PROCESS signal={signum} pid={host['pid']} start={host['start']} executable={host['path']}", flush=True)
        try: send(host["pid"], signum)
        except ProcessLookupError:
            if process.poll() is not None: return
            raise ValueError("ESRCH without verified owned child exit") from None
        deadline = now() + 2
        while now() < deadline:
            if process.poll() is not None: return
            pause(0.02)
    if process.poll() is None: raise ValueError(f"owned launch has not exited: {host}")


def run_ua_commands(invoke):
    primary, exited = invoke("primary")
    primary = 128 - primary if primary < 0 else primary
    if not exited: return primary or 1
    cleanup, cleanup_exited = invoke("cleanup")
    cleanup = 128 - cleanup if cleanup < 0 else cleanup
    return primary or cleanup or (0 if cleanup_exited else 1)


def validate_ua_options(options):
    if options.extension_user_agent_only and any((options.app, options.distribution, options.lifecycle,
                                                 options.public_media, options.crash_recovery)):
        raise ValueError("--extension-user-agent-only is exclusive; only --binary is supported with it")


def run_ua_trials(trial, count=8):
    if not 1 <= count <= 8: raise ValueError("UA comparison requires one to eight fresh trials")
    for number in range(1, count + 1):
        status = trial(number)
        if status: return status
    return 0


def drain_ua_output(descriptor, output, limit=UA_OUTPUT_LIMIT):
    """Consume one nonblocking 16 KiB poll; retain at most the output budget."""
    consumed = 0
    overflow = False
    interruptions = 0
    while consumed < 16_384:
        try: chunk = os.read(descriptor, min(4096, 16_384 - consumed))
        except BlockingIOError: break
        except InterruptedError:
            interruptions += 1
            if interruptions >= 8: break
            continue
        if not chunk: break
        consumed += len(chunk)
        remaining = max(0, limit - len(output))
        output.extend(chunk[:remaining])
        overflow |= len(chunk) > remaining
    return consumed, overflow


def run_ua_process(command, environment, timeout, log, interrupted):
    # Reuse the existing kernel identity reader without running its test driver.
    spec = importlib.util.spec_from_file_location("ua_native_identity", Path(__file__).with_name("run-native-tests.py"))
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    process = None
    host = None
    output = bytearray()
    overflow = False
    status = 1
    exited = False
    try:
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        expected = os.path.realpath(command[0])
        identity_deadline = time.monotonic() + 0.25
        while process.poll() is None:
            observed = native.process_identity(process.pid)
            if observed and observed["path"] == expected:
                host = observed
                break
            if time.monotonic() >= identity_deadline:
                raise ValueError(f"cannot verify launched executable: pid={process.pid} expected={expected}")
            time.sleep(0.01)
        print(f"UA OWNED PROCESS launched pid={process.pid} identity={host} executable={expected}", flush=True)
        os.set_blocking(process.stdout.fileno(), False)
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            _, dropped = drain_ua_output(process.stdout.fileno(), output)
            overflow |= dropped
            requested = interrupted[0]
            if requested or time.monotonic() >= deadline:
                interrupted[0] = None
                if host is None: raise ValueError("cannot stop an unverified launch")
                stop_ua_launch(host, process, native.process_identity, os.kill, time.sleep, time.monotonic)
                status = 128 + requested if requested else 124
                break
            time.sleep(0.02)
        else: status = process.returncode
        exited = process.poll() is not None
        # Drain only immediately available bytes; never wait for a descendant's EOF.
        for _ in range(65):
            consumed, dropped = drain_ua_output(process.stdout.fileno(), output)
            overflow |= dropped
            if consumed == 0: break
        if overflow or re.search(rb"(?m)^\*\*\* Signal [0-9]+: Backtracing", output): status = status or 1
    except Exception as error:
        print(f"FAIL UA owned process: {error}", file=sys.stderr, flush=True)
        if process is not None:
            try:
                if process.poll() is None and host is not None:
                    stop_ua_launch(host, process, native.process_identity, os.kill, time.sleep, time.monotonic)
            except Exception as cleanup_error:
                print(f"FAIL UA process exit unverified: pid={process.pid}; {cleanup_error}", file=sys.stderr, flush=True)
            exited = process.poll() is not None
        status = 1
    finally:
        if process is not None and process.stdout is not None: process.stdout.close()
        try: log.write_bytes(output)
        except OSError as error:
            print(f"FAIL UA output could not be preserved: {error}", file=sys.stderr, flush=True)
            status = status or 1
    if status:
        print("UA owned-process bounded output tail:\n" + bytes(output[-65_536:]).decode("utf-8", errors="replace"), flush=True)
    print(f"UA OWNED PROCESS exited={exited} status={status} outputTruncated={overflow} log={log}", flush=True)
    return status, exited, bytes(output)


def run_ua_mode(binary, root, downloads, evidence_dir, observer_mode):
    validate_observer_mode(observer_mode)
    if not binary.is_file(): raise ValueError("requires a built debug Vane executable")
    # This fresh, log-only directory is outside disposable bundles/profiles and
    # intentionally survives every success/failure path. Refuse overwrite/reuse.
    evidence_dir = evidence_dir.resolve()
    evidence_dir.mkdir(mode=0o700)
    print(f"UA OBSERVER ARM mode={observer_mode} plannedFreshLaunches=8 both-success=inconclusive", flush=True)
    interrupted = [None]
    previous = {sig: signal.signal(sig, lambda signum, frame: interrupted.__setitem__(0, signum))
                for sig in (signal.SIGINT, signal.SIGTERM)}
    def trial(number):
        if interrupted[0]: return 128 + interrupted[0]
        trial_logs = evidence_dir / f"trial-{number:02d}"
        trial_logs.mkdir(mode=0o700)
        bundle_root = Path(tempfile.mkdtemp(prefix="vane-extension-ua-")).resolve()
        data = Path(tempfile.mkdtemp(prefix=".vane-extension-ua-", dir=downloads)).resolve()
        app = bundle_root / "Vane UA Check.app"
        executable = app / "Contents/MacOS/vane"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.github.notnaki.vane.browsercheck." + uuid.uuid4().hex,
            "CFBundleExecutable": "vane", "CFBundleName": "Vane UA Check", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1", "NSPrincipalClass": "NSApplication",
            "LSMinimumSystemVersion": "26.0"}))
        environment = {name: os.environ[name] for name in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if name in os.environ}
        environment["VANE_DATA_DIR"] = str(data)
        print(f"UA normal-loop trial {number}/8 bundle={app} data={data} binarySHA256={hashlib.sha256(executable.read_bytes()).hexdigest()}", flush=True)
        signed, signer_exited, _ = run_ua_process(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(root / "Vane.entitlements"), str(app)],
            environment, 30, trial_logs / "signing.log", interrupted)
        if signed or not signer_exited:
            print(f"FAIL UA signing; artifacts retained at {bundle_root} and {data}", flush=True)
            return signed or 1
        cleanup_verified = False
        def invoke(phase):
            nonlocal cleanup_verified
            # A signal received between primary exit and cleanup must not skip
            # the post-exit retirement attempt. A new signal during it still stops
            # its exact owned process through the normal bounded path.
            pending_signal = interrupted[0] if phase == "cleanup" else None
            if phase == "cleanup": interrupted[0] = None
            command = [str(executable), "extensioncheck", "--user-agent-only", "--ua-loader-start-observer-mode", observer_mode] if phase == "primary" else [str(executable), "browsercheck-cleanup"]
            status, exited, output = run_ua_process(command, environment, 90 if phase == "primary" else 25,
                                                    trial_logs / (phase + ".log"), interrupted)
            if status == 0 and exited:
                try:
                    if phase == "primary":
                        branch = validate_ua_observer(output, observer_mode)
                        validate_ua_report(data / "extensioncheck-results.json", echo_verified=True)
                        print("UA OBSERVER ATTESTATION " + json.dumps(branch, sort_keys=True), flush=True)
                    else: validate_ua_cleanup(output); cleanup_verified = True
                except ValueError as error:
                    print(f"FAIL UA {phase} attestation: {error}", file=sys.stderr, flush=True)
                    print("UA failed-attestation bounded output tail:\n" + output[-65_536:].decode("utf-8", errors="replace"), flush=True)
                    status = 1
            if pending_signal: status = status or 128 + pending_signal
            return status, exited
        status = run_ua_commands(invoke)
        if status == 0 and cleanup_verified:
            shutil.rmtree(data)
            shutil.rmtree(bundle_root)
            print(f"PASS normal-loop UA trial {number}: all five verified stages and post-exit store cleanup", flush=True)
        else:
            print(f"FAIL UA trial {number}; artifacts retained at {bundle_root} and {data}", flush=True)
        return status
    try: return run_ua_trials(trial)
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)


def main():
    parser = ua_argument_parser()
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    binary = (options.binary or root / '.build/debug/vane').resolve()
    downloads = Path.home() / 'Downloads'
    if not downloads.is_dir(): parser.error('~/Downloads must exist for isolated sandbox profiles')
    try: return run_ua_mode(binary, root, downloads, options.evidence_dir, options.observer_mode)
    except (OSError, ValueError) as error:
        print(f'FAIL signed extension UA comparison: {error}', file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__': raise SystemExit(main())
