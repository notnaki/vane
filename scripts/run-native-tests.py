#!/usr/bin/env python3
"""Run unchanged Swift tests, then retire only their manifest-owned WebKit stores.

Use this for full or focused native validation: run-native-tests.py [swift test args].
Failed/unverified cleanup keeps its private manifest for a concrete follow-up.
Diagnostic opt-in: VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT=1..3600 bounds only the
primary driver. Unset retains the ordinary wait; fresh cleanup keeps its 90s bound.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

DIRECTORY_ENV = "VANE_NATIVE_FIXTURE_MANIFEST_DIR"
TOKEN_ENV = "VANE_NATIVE_FIXTURE_MANIFEST_TOKEN"
PHASE_ENV = "VANE_NATIVE_FIXTURE_RETIREMENT_PHASE"
SELECTOR = "VaneTests.NativeFixtureRetirementTests/testRetireManifest"
FORBIDDEN = {"00000000-0000-0000-0000-000056616e65", "00000000-0000-0000-0000-000000000001"}
PRIMARY_TIMEOUT_ENV = "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT"


class PrimaryTimeoutError(RuntimeError):
    pass


def parse_primary_timeout(value):
    if value is None: return None
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,3}", value) or int(value) > 3600:
        raise ValueError(PRIMARY_TIMEOUT_ENV + " must be an integer from 1 through 3600 seconds")
    return int(value)


def stop_primary_driver(process):
    # Popen owns this unreaped direct child; its PID cannot be reused before
    # wait/poll reaps it. Never target a process name, descendant, or group.
    if process.poll() is not None: return
    try: process.terminate()
    except ProcessLookupError:
        if process.poll() is not None: return
        raise
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if process.poll() is None: process.kill()
        process.wait(timeout=5)


def require_record_inclusion(previous, current):
    def host_identity(record):
        host = record["host"]
        return (host["pid"], host["start"], os.path.realpath(host["path"]),
                os.path.realpath(host["testBundlePath"]), host["processName"], host["bundleIdentifier"])
    def profile_identities(record):
        return {(str(uuid.UUID(entry["profileID"])), entry["dataDirectory"], str(uuid.UUID(entry["storeID"])))
                for entry in record["profiles"]}
    initial_hosts = {host_identity(record) for record in previous}
    if not initial_hosts.issubset({host_identity(record) for record in current}):
        raise ValueError("primary timeout lost or changed a previously validated host identity; manifest retained")
    fresh_profiles = {host_identity(record): profile_identities(record) for record in current}
    if any(not profile_identities(record).issubset(fresh_profiles[host_identity(record)]) for record in previous):
        raise ValueError("primary timeout lost a previously validated profile/backend entry; manifest retained")


def retire_timed_out_primary(process, directory, token):
    try:
        records = load_records(directory, token)  # Validate ALL before any host signal.
        if not records: raise ValueError("primary timeout has no recorded host identity; manifest retained")
        initial_records = records
    finally:
        # This must run even if the manifest is missing, malformed, or untrusted.
        stop_primary_driver(process)
    # The Swift driver has exited and cannot launch another test host. Validate
    # again so a host recorded while it was exiting is not missed.
    records = load_records(directory, token)
    if not records: raise ValueError("primary timeout lost its recorded host identity; manifest retained")
    require_record_inclusion(initial_records, records)
    failures = []
    for record in records:
        try: stop_recorded_host(record["host"])
        except Exception as error: failures.append(str(error))
    try: require_exited_hosts(records)
    except Exception as error: failures.append(str(error))
    if failures: raise ValueError("primary timeout retirement unverified: " + "; ".join(failures))
    return records


def _absolute(path):
    return isinstance(path, str) and path.startswith("/") and not path.startswith("//") and "\0" not in path and os.path.normpath(path) == path and path != "/"


def validate_record(record, token):
    if not isinstance(record, dict) or record.get("schema") != 1 or record.get("token") != token:
        raise ValueError("manifest contract mismatch")
    host = record.get("host", {})
    if not isinstance(host, dict) or any(type(host.get(key)) is not int or host[key] <= 0 for key in ("pid", "start")):
        raise ValueError("missing test-host identity")
    if not _absolute(host.get("path")) or not _absolute(host.get("testBundlePath")) or not host["testBundlePath"].endswith(".xctest"):
        raise ValueError("invalid test-host executable/bundle")
    if not isinstance(host.get("processName"), str) or not host["processName"] or not isinstance(host.get("bundleIdentifier"), str):
        raise ValueError("missing WebKit host namespace")
    profiles = record.get("profiles")
    if not isinstance(profiles, list) or len(profiles) > 4096:
        raise ValueError("invalid owned profile list")
    for entry in profiles:
        if not isinstance(entry, dict): raise ValueError("invalid profile entry")
        try: profile = str(uuid.UUID(entry["profileID"]))
        except (KeyError, ValueError, TypeError, AttributeError): raise ValueError("invalid profile UUID") from None
        directory = entry.get("dataDirectory")
        if profile in FORBIDDEN or not _absolute(directory): raise ValueError("non-disposable profile or namespace")
        raw = bytearray(hashlib.sha256(("Vane.WebsiteData.v1\0" + directory + "\0" + profile).encode()).digest()[:16])
        raw[:4] = b"VANE"
        raw[6] = (raw[6] & 15) | 128
        raw[8] = (raw[8] & 63) | 128
        try: store = str(uuid.UUID(entry["storeID"]))
        except (KeyError, ValueError, TypeError, AttributeError): raise ValueError("invalid backend UUID") from None
        if store != str(uuid.UUID(bytes=bytes(raw))): raise ValueError("backend UUID does not belong to recorded isolated profile")
    return record


def read_private_json(path):
    try: descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error: raise ValueError("cannot open private manifest: " + str(path)) from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 1048576:
            raise ValueError("manifest must be a bounded private regular file")
        data = os.read(descriptor, 1048577)
        if len(data) > 1048576: raise ValueError("manifest too large")
        return json.loads(data)
    finally: os.close(descriptor)


def load_records(directory, token):
    directory = Path(directory)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700 or directory.resolve() != directory:
        raise ValueError("manifest directory must be private and canonical")
    contract = read_private_json(directory / "contract.json")
    if contract != {"schema": 1, "token": token}: raise ValueError("invalid wrapper contract")
    paths = sorted(directory.glob("host-*.json"))
    if len(paths) > 256: raise ValueError("too many test hosts")
    records = [validate_record(read_private_json(path), token) for path in paths]
    for path, record in zip(paths, records):
        host = record["host"]
        if path.name != f'host-{host["pid"]}-{host["start"]}.json': raise ValueError("host manifest name mismatch")
    return records


def process_identity(pid):
    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "rfu")]
        _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice")]
        _fields_ += [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    info = BSDInfo()
    path = ctypes.create_string_buffer(4096)
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        try: os.kill(pid, 0)
        except ProcessLookupError: return None
        except PermissionError: pass
        raise ValueError(f"cannot verify test-host identity pid={pid}")
    if library.proc_pidpath(pid, path, len(path)) <= 0: raise ValueError(f"cannot verify test-host executable pid={pid}")
    return {"pid": pid, "start": info.seconds * 1000000 + info.microseconds, "path": os.path.realpath(os.fsdecode(path.value))}


def require_exited_hosts(records, identity=process_identity):
    for record in records:
        host = record["host"]
        observed = identity(host["pid"])
        if observed is not None and observed["start"] == host["start"]:
            raise ValueError(f'owned test host has not exited or cannot be revalidated: pid={host["pid"]} start={host["start"]}')


def stop_recorded_host(host, identity=process_identity, send=os.kill, pause=time.sleep, now=time.monotonic):
    """Only a positively revalidated cleanup-host launch may receive a signal."""
    def alive():
        observed = identity(host["pid"])
        if observed is None or observed["start"] != host["start"]: return False
        if os.path.realpath(observed["path"]) != os.path.realpath(host["path"]):
            raise ValueError(f'cleanup host identity changed; no signal sent: pid={host["pid"]} start={host["start"]} executable={host["path"]}')
        return True
    for signum in (signal.SIGTERM, signal.SIGKILL):
        if not alive(): return
        # Revalidate at the signal boundary; never target a name or a process group.
        if not alive(): return
        print(f'NATIVE CLEANUP HOST signal={signum} pid={host["pid"]} start={host["start"]} executable={host["path"]}', flush=True)
        try: send(host["pid"], signum)
        except ProcessLookupError:
            if not alive(): return
            raise  # ESRCH alone cannot substitute for verified launch disappearance.
        deadline = now() + 2
        while now() < deadline:
            try:
                if not alive(): return
            except ValueError:
                # An exiting child can briefly lose proc metadata before ESRCH.
                # Wait for verified exit; never signal an unverified identity.
                pass
            pause(0.02)
    if alive(): raise ValueError(f'owned cleanup host remains running: pid={host["pid"]} start={host["start"]} executable={host["path"]}')


def finish_recorded_cleanup_host(directory, token):
    path = Path(directory) / "cleanup-host.json"
    if not path.exists(): return False
    record = validate_record(read_private_json(path), token)
    stop_recorded_host(record["host"])
    require_exited_hosts([record])
    return True


def run_commands(primary, cleanup, invoke, require_exited):
    primary_status = 1
    cleanup_status = 1
    try:
        primary_status = invoke(primary)
    except PrimaryTimeoutError as error:
        primary_status = 124
        print("Primary command timed out: " + str(error), file=sys.stderr)
    except KeyboardInterrupt: primary_status = 130
    except Exception as error: print("Primary command failed: " + str(error), file=sys.stderr)
    finally:
        try:
            require_exited()
            cleanup_status = invoke(cleanup)
        except Exception as error: print("Cleanup refused/failed: " + str(error), file=sys.stderr)
    print(f"Native suite primary status={primary_status}; cleanup status={cleanup_status}", flush=True)
    result = primary_status if primary_status != 0 else cleanup_status
    return 128 - result if result < 0 else result


def main(arguments):
    if sys.platform != "darwin": raise SystemExit("native tests require macOS")
    if any(arg == "--parallel" or arg.startswith("--num-workers") for arg in arguments):
        raise SystemExit("native fixture tests require one host; --parallel is unsupported")
    # Unset preserves the ordinary primary wait. Only explicitly bounded
    # diagnostics opt in; malformed values fail before launching any process.
    primary_timeout = parse_primary_timeout(os.environ.get(PRIMARY_TIMEOUT_ENV))
    directory = Path(tempfile.mkdtemp(prefix="vane-native-retirement-")).resolve()
    os.chmod(directory, 0o700)
    token = uuid.uuid4().hex
    contract = directory / "contract.json"
    contract.write_text(json.dumps({"schema": 1, "token": token}))
    os.chmod(contract, 0o600)
    environment = dict(os.environ, **{DIRECTORY_ENV: str(directory), TOKEN_ENV: token})
    environment.pop(PHASE_ENV, None)
    primary = ["swift", "test", *arguments]
    cleanup = ["swift", "test", "--skip-build", "--filter", SELECTOR]
    # Mirror configuration/toolchain options that locate the exact test bundle.
    pair_options = {"--configuration", "-c", "--scratch-path", "--package-path", "--triple", "--sdk", "--toolchain", "--arch"}
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        if arg in pair_options:
            if index + 1 >= len(arguments): raise SystemExit("missing value for " + arg)
            cleanup.extend(arguments[index:index + 2]); index += 2
        else:
            if any(arg.startswith(option + "=") for option in pair_options): cleanup.append(arg)
            index += 1
    active = None
    def forward(signum, frame):
        nonlocal active
        if active is not None and active.poll() is None:
            active.send_signal(signum)  # Popen still owns this unreaped child's identity.
    previous = {signum: signal.signal(signum, forward) for signum in (signal.SIGINT, signal.SIGTERM)}
    records = []
    verified_cleanup = False
    primary_timed_out = False
    primary_timeout_verified = False
    timeout_verified_records = []
    def check_hosts():
        nonlocal records
        if primary_timed_out and not primary_timeout_verified:
            raise ValueError("primary timeout ownership/exit unverified; cleanup refused; manifest retained")
        records = load_records(directory, token)  # Validate ALL records before deletion.
        if primary_timed_out:
            if not records: raise ValueError("primary timeout has no host records at cleanup recheck; manifest retained")
            require_record_inclusion(timeout_verified_records, records)
        require_exited_hosts(records)
        prior_cleanup = directory / "cleanup-host.json"
        if prior_cleanup.exists(): require_exited_hosts([validate_record(read_private_json(prior_cleanup), token)])
    def invoke(command):
        nonlocal active, verified_cleanup, primary_timed_out, primary_timeout_verified, timeout_verified_records
        is_cleanup = command is cleanup
        if is_cleanup and not records:
            verified_cleanup = True
            return 0  # A compilation failure may never launch a test host.
        child_environment = dict(environment)
        if is_cleanup: child_environment[PHASE_ENV] = "cleanup"
        active = subprocess.Popen(command, env=child_environment)
        print(f"NATIVE TEST DRIVER pid={active.pid} phase={'cleanup' if is_cleanup else 'primary'}", flush=True)
        try:
            status = active.wait(timeout=90 if is_cleanup else primary_timeout)
        except subprocess.TimeoutExpired:
            if not is_cleanup:
                primary_timed_out = True
                print(f"NATIVE PRIMARY TIMEOUT seconds={primary_timeout}; validating recorded hosts before retirement", flush=True)
                try: timeout_verified_records = retire_timed_out_primary(active, directory, token)
                except Exception as error: raise PrimaryTimeoutError(str(error)) from error
                primary_timeout_verified = True
                active = None
                return 124
            active.terminate()
            try: active.wait(timeout=5)
            except subprocess.TimeoutExpired:
                active.kill()
                active.wait()
            if not finish_recorded_cleanup_host(directory, token):
                raise ValueError("cleanup timed out before recording actual host identity; native host exit is unverified; manifest retained") from None
            raise ValueError("fresh cleanup driver exceeded its deadline; verify recorded cleanup host before any follow-up") from None
        active = None
        if is_cleanup:
            finish_recorded_cleanup_host(directory, token)
            if status == 0:
                result = read_private_json(directory / "complete.json")
                expected = sorted({entry["storeID"].lower() for record in records for entry in record["profiles"]})
                if result != {"schema": 1, "token": token, "retiredIDs": expected}:
                    raise ValueError("cleanup did not verify every owned backend")
                verified_cleanup = True
        return status
    try:
        status = run_commands(primary, cleanup, invoke, check_hosts)
    finally:
        for signum, handler in previous.items(): signal.signal(signum, handler)
        if verified_cleanup: shutil.rmtree(directory)
        else: print("UNVERIFIED native fixture retirement; private manifest retained: " + str(directory), file=sys.stderr)
    return status


if __name__ == "__main__": raise SystemExit(main(sys.argv[1:]))
