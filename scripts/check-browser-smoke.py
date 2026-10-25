#!/usr/bin/env python3
"""Run real WebKit smoke checks in an isolated signed sandbox bundle.

Requires macOS 26 and a logged-in graphical session. This verifies sandbox behavior,
not installation. By default it creates an ad-hoc fixture from a built Vane executable.
Use --app to test an existing bundle unchanged, and --distribution to require the
Developer ID, notarization, and Gatekeeper checks used for a release candidate.
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


def validate_ua_report(path):
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
        if finding["workflow"] == UA_LABELS[0] and not re.fullmatch(
                r"finishedLaunching=true; appRunning=true; WebKit=[^\r\n;]{1,160}; OS=[^\r\n]{1,160}", finding["detail"]):
            raise ValueError("UA normal application-loop attestation is missing")
    if any(not isinstance(label, str) for label in labels) or sorted(labels) != sorted(UA_LABELS):
        raise ValueError("UA stages were missing, duplicated, or unknown")
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


def run_ua_mode(binary, root, downloads):
    if not binary.is_file(): raise ValueError("requires a built debug Vane executable")
    interrupted = [None]
    previous = {sig: signal.signal(sig, lambda signum, frame: interrupted.__setitem__(0, signum))
                for sig in (signal.SIGINT, signal.SIGTERM)}
    def trial(number):
        if interrupted[0]: return 128 + interrupted[0]
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
            environment, 30, bundle_root / "signing.log", interrupted)
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
            command = [str(executable), "extensioncheck", "--user-agent-only"] if phase == "primary" else [str(executable), "browsercheck-cleanup"]
            status, exited, output = run_ua_process(command, environment, 90 if phase == "primary" else 25,
                                                    bundle_root / (phase + ".log"), interrupted)
            if status == 0 and exited:
                try:
                    if phase == "primary": validate_ua_report(data / "extensioncheck-results.json")
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


def run_checked(command, description):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if result.stdout:
        print(result.stdout.rstrip(), flush=True)
    if result.returncode:
        print(f"FAIL: {description}", file=sys.stderr)
        raise SystemExit(1)
    return result.stdout


def verify_distribution(app):
    run_checked(["codesign", "--verify", "--deep", "--strict", str(app)],
                "release app has an invalid code signature")
    signing = run_checked(["codesign", "-dvv", str(app)],
                          "release app signing information is unavailable")
    team = next((line.partition("=")[2] for line in signing.splitlines()
                 if line.startswith("TeamIdentifier=")), "")
    if team != TEAM_ID:
        print(f"FAIL: release app TeamIdentifier is {team or 'missing'}, expected {TEAM_ID}",
              file=sys.stderr)
        raise SystemExit(1)
    run_checked(["xcrun", "stapler", "validate", str(app)],
                "release app has no valid stapled notarization ticket")
    run_checked(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
                "Gatekeeper rejected the release app")
    print(f"Verified Developer ID distribution bundle (team {TEAM_ID}).", flush=True)


def executable_in(app, parser):
    info_path = app / "Contents/Info.plist"
    if not app.is_dir() or not info_path.is_file():
        parser.error("--app must name an application bundle containing Contents/Info.plist")
    try:
        executable_name = plistlib.loads(info_path.read_bytes())["CFBundleExecutable"]
    except (OSError, plistlib.InvalidFileException, KeyError, TypeError):
        parser.error("--app Info.plist must contain a valid CFBundleExecutable")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--app CFBundleExecutable must name an executable file")
    return executable



def run_fixture(command, environment, app, timeout):
    with subprocess.Popen(command, env=environment) as process:
        started = subprocess.check_output(
            ["ps", "-p", str(process.pid), "-o", "lstart="], text=True).strip()
        print(f"TEST PROCESS bundle={app} pid={process.pid} start={started} launched={datetime.now().isoformat()}", flush=True)
        stopped = threading.Event()
        injection_errors = []

        def terminate_content():
            request = Path(environment["VANE_DATA_DIR"]) / "terminate-webcontent.json"
            seen = set()
            while not stopped.wait(0.05) and process.poll() is None:
                if not request.exists():
                    continue
                try:
                    event = json.loads(request.read_text())
                    if event["token"] in seen:
                        continue
                    seen.add(event["token"])
                    pid = int(event["pid"])
                    identity = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart=,comm="], text=True).strip()
                    if pid <= 0 or "com.apple.WebKit.WebContent" not in identity:
                        raise RuntimeError("reported process is not a live WebKit content service")
                    print(f"TEST WEBKIT pid={pid} identity={identity}", flush=True)
                    current = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart=,comm="], text=True).strip()
                    if current != identity:
                        raise RuntimeError("WebKit process identity changed before signal")
                    os.kill(pid, signal.SIGKILL)
                except Exception as error:
                    injection_errors.append(str(error))
                    print(f"FAIL WebKit termination injection: {error}", flush=True)
                    return

        injector = None
        if "--crash-recovery" in command:
            injector = threading.Thread(target=terminate_content, daemon=True)
            injector.start()

        def stop_owned(sig):
            if process.poll() is not None:
                return
            identity = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "lstart=,comm="], text=True).strip()
            if started not in identity or str(Path(command[0]).resolve()) not in identity:
                raise RuntimeError("owned app process identity changed before cleanup")
            process.send_signal(sig)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The unreaped child PID cannot be reused; target only this owned process.
            stop_owned(signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop_owned(signal.SIGKILL)
                process.wait()
            print(f"TEST PROCESS terminated pid={process.pid}", flush=True)
            raise
        finally:
            stopped.set()
            if injector:
                injector.join(timeout=5)
        print(f"TEST PROCESS exited pid={process.pid} code={code}", flush=True)
        return code or bool(injection_errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--binary", type=Path,
                        help="built executable to place in a temporary ad-hoc fixture")
    source.add_argument("--app", type=Path,
                        help="existing signed app bundle to execute without changing it")
    parser.add_argument("--distribution", action="store_true",
                        help="require Developer ID, notarization, and Gatekeeper checks")
    parser.add_argument("--lifecycle", action="store_true", help="100 tab/window cycles, 25 suspend/resume cycles, 200 parked rows, settling and idle CPU")
    parser.add_argument("--public-media", action="store_true", help="opt-in sustained Shaka public-demo playback (network required, no accounts)")
    parser.add_argument("--crash-recovery", action="store_true", help="synthetic active/background WebKit process kills and POST recovery")
    parser.add_argument("--extension-user-agent-only", action="store_true",
                        help="diagnostic-only: eight fresh signed normal-loop UA hosts, each followed by verified store retirement")
    options = parser.parse_args()
    try: validate_ua_options(options)
    except ValueError as error: parser.error(str(error))
    if options.lifecycle and options.public_media:
        parser.error("--lifecycle and --public-media are separate passes")
    if options.distribution and options.app is None:
        parser.error("--distribution requires --app")
    if sys.platform != "darwin":
        parser.error("requires macOS")
    downloads = Path.home() / "Downloads"
    if not downloads.is_dir():
        parser.error("~/Downloads must exist for the sandbox-isolated test directory")

    binary = (options.binary or root / ".build/debug/vane").resolve()
    if options.extension_user_agent_only:
        return run_ua_mode(binary, root, downloads)
    app = options.app.resolve() if options.app else None
    if app:
        executable = executable_in(app, parser)
        if options.distribution:
            verify_distribution(app)
        bundle_context = None
        message = "Running supplied signed app bundle unchanged."
    else:
        if not binary.is_file():
            parser.error("requires a built Vane executable (--binary)")
        bundle_context = tempfile.TemporaryDirectory(prefix="vane-browser-smoke-")
        app = Path(bundle_context.name) / "Vane Browser Check.app"
        executable = app / "Contents/MacOS/vane"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        info = {
            "CFBundleIdentifier": "io.github.notnaki.vane.browsercheck." + uuid.uuid4().hex,
            "CFBundleExecutable": "vane",
            "CFBundleName": "Vane Browser Check",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "0.1",
            "NSPrincipalClass": "NSApplication",
            "LSMinimumSystemVersion": "26.0",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run([
            "codesign", "--force", "--sign", "-", "--entitlements",
            str(root / "Vane.entitlements"), str(app),
        ], check=True)
        message = "Running ad-hoc signed sandbox fixture."

    # The production Downloads entitlement admits this directory without adding a
    # sandbox exception. The environment is deliberately allowlisted so CI secrets are
    # never inherited by the app under test.
    with tempfile.TemporaryDirectory(prefix=".vane-browser-smoke-", dir=downloads) as data:
        environment = {name: os.environ[name] for name in
                       ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG")
                       if name in os.environ}
        environment["VANE_DATA_DIR"] = data
        print("TEST EXECUTABLE sha256=" + hashlib.sha256(executable.read_bytes()).hexdigest(), flush=True)
        print(message + " Requires a graphical session.", flush=True)
        try:
            try:
                command = [str(executable), "browsercheck"] + (["--lifecycle"] if options.lifecycle else [])
                if options.public_media:
                    command.append("--public-media")
                if options.crash_recovery:
                    command.append("--crash-recovery")
                browser_code = run_fixture(command, environment, app, 620 if options.lifecycle or options.public_media else 75)
            except subprocess.TimeoutExpired:
                print("FAIL: browser smoke process exceeded its deadline", file=sys.stderr)
                browser_code = 1

            # WebKit's network process holds the named data store open throughout the
            # browsercheck invocation. Re-enter the same signed app after it exits to
            # unregister the isolated store and verify that WebKit no longer lists it.
            try:
                cleanup_code = run_fixture([str(executable), "browsercheck-cleanup"], environment, app, 20)
            except subprocess.TimeoutExpired:
                print("FAIL: browser smoke cleanup exceeded 20 seconds", file=sys.stderr)
                cleanup_code = 1
            return browser_code or cleanup_code
        finally:
            if bundle_context is not None:
                bundle_context.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
