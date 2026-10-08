#!/usr/bin/env python3
"""Disposable AppKit launch/rollback tests. Coordinate a native slot first.

Uses signed disposable copies and VANE_DATA_DIR under Downloads. Relaunch explicitly
propagates isolation and creates a new instance. The previous app is an unchanged
signed release. Native candidate notarization is simulated by the transaction driver;
real distribution checks run separately through test-update-installer.
"""
import argparse
import ctypes
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--previous', type=pathlib.Path, required=True)
parser.add_argument('--bootstrap-failure', action='store_true', help='requires SIGN_ID to sign an early-exit candidate')
parser.add_argument('--evidence', type=pathlib.Path, required=True)
options = parser.parse_args()
options.evidence.mkdir(parents=True, exist_ok=True)
owned = {}



# macOS can translocate a restored release reopened from a sandbox. Resolve the
# original path before cleanup; never identify task copies by Vane's shared bundle ID.
_cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
_security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
_cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
_cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
_security.SecTranslocateCreateOriginalPathForURL.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
_security.SecTranslocateCreateOriginalPathForURL.restype = ctypes.c_void_p
_cf.CFURLGetFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_void_p, ctypes.c_long]
_cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
_cf.CFRelease.argtypes = [ctypes.c_void_p]

def original_path(path):
    raw = os.fsencode(path)
    url = _cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), False)
    error = ctypes.c_void_p()
    original = _security.SecTranslocateCreateOriginalPathForURL(url, ctypes.byref(error))
    try:
        buffer = ctypes.create_string_buffer(4096)
        if original and _cf.CFURLGetFileSystemRepresentation(original, True, buffer, len(buffer)):
            return os.fsdecode(buffer.value)
        return None
    finally:
        if original: _cf.CFRelease(original)
        if error.value: _cf.CFRelease(error)
        if url: _cf.CFRelease(url)


def processes(root):
    output = subprocess.check_output(['ps', '-axo', 'pid=,lstart=,command='], text=True)
    result = {}
    for line in output.splitlines():
        match = re.match(r'\s*(\d+)\s+(.{24})\s+(.+)', line)
        if not match: continue
        pid, start, command = int(match[1]), match[2], match[3]
        local = str(root) in command and ('/Contents/MacOS/' in command or '/bin/sh -c' in command or str(root / 'install') in command)
        translocated = False
        if '/AppTranslocation/' in command and '/Contents/MacOS/Vane' in command:
            executable = command.split(' ')[0]
            original = original_path(executable)
            if original is None:
                bundle = executable.split('/Contents/MacOS/')[0]
                source = original_path(bundle)
                if source is not None: original = source + executable[len(bundle):]
            translocated = original is not None and original.startswith(str(root) + '/')
            # If macOS already discarded the translocation mount, the recorded exact
            # executable/start identity still belongs to the previously proven fixture.
            translocated = translocated or owned.get(pid) == (start, command)
        if local or translocated:
            result[pid] = (start, command)
    return result


def track(root):
    for pid, value in processes(root).items():
        if pid not in owned:
            owned[pid] = value
            print(f'TEST PROCESS pid={pid} start={value[0]} executable={value[1]}', flush=True)
    return processes(root)


def stop(pid, root, sig=signal.SIGTERM):
    # Revalidate executable path and start time before every signal, including KILL.
    current = processes(root)
    if pid in current and current[pid] == owned.get(pid):
        os.kill(pid, sig)


def until(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for updater state')


def version(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']


with tempfile.TemporaryDirectory(prefix='.vane-updater-native-', dir=pathlib.Path.home() / 'Downloads') as directory:
    work = pathlib.Path(directory).resolve()
    driver = work / 'Driver.app'
    sandboxed_helper = driver / 'Contents/MacOS/Driver'
    helper = work / 'install'
    sandboxed_helper.parent.mkdir(parents=True)
    identifier = 'io.github.notnaki.vane.UpdaterNative.' + work.name.removeprefix('.vane-updater-native-').replace('_', '-')
    (driver / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Driver',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1', 'CFBundleName': 'Updater Native Fixture'}))
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Sources/Vane/BundleReplacement.swift'),
                    str(ROOT / 'Sources/Vane/UpdateInstaller.swift'), str(ROOT / 'Sources/Vane/UpdateRelaunch.swift'), str(ROOT / 'Tests/UpdaterNative/main.swift'), '-o', str(helper)], check=True)
    shutil.copy2(helper, sandboxed_helper)
    # Installation runs outside the sandbox, as XPC does. Only restart inherits
    # the browser sandbox, including its shell and signed helper descendants.
    subprocess.run(['codesign', '--force', '--sign', os.environ.get('SIGN_ID', '-'),
                    '--entitlements', str(ROOT / 'Vane.entitlements'), str(driver)], check=True)
    templates = {}
    for kind, original in [('old', options.previous), ('new', options.app)]:
        app = work / (kind + '.app')
        shutil.copytree(original.resolve(), app, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
        templates[kind] = app
    old_version, new_version = version(templates['old']), version(templates['new'])
    if options.bootstrap_failure:
        identity = os.environ.get('SIGN_ID')
        assert identity, 'SIGN_ID is required for the bootstrap failure fixture'
        stub = work / 'stub.app'
        shutil.copytree(templates['new'], stub, symlinks=True)
        source_code = work / 'stub.c'
        source_code.write_text('#include <stdlib.h>\n#include <stdio.h>\nint main(void) { const char *d=getenv("VANE_DATA_DIR"); if(d) { char p[4096]; snprintf(p,sizeof(p),"%s/bootstrap-environment",d); FILE *f=fopen(p,"w"); if(f) { fputs(d,f); fclose(f); } } return 1; }\n')
        subprocess.run(['xcrun', 'clang', str(source_code), '-o', str(stub / 'Contents/MacOS/Vane')], check=True)
        subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--entitlements', str(ROOT / 'Vane.entitlements'), '--sign', identity, str(stub)], check=True)
        templates['stub'] = stub
    environment = {key: os.environ[key] for key in ['HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG'] if key in os.environ}
    try:
        for scenario in ['healthy', 'crashed-launch', 'corrupted-new'] + (['failed-bootstrap', 'failed-bootstrap-stale', 'failed-bootstrap-malformed'] if options.bootstrap_failure else []):
            scene = work / scenario
            scene.mkdir()
            target = scene / 'Vane.app'
            shutil.copytree(templates['old'], target, symlinks=True)
            subprocess.run([str(helper), str(templates['stub'] if scenario.startswith('failed-bootstrap') else templates['new']), str(target)], check=True)
            record = scene / '.Vane.app.vane-transaction.json'
            journal = json.loads(record.read_text())
            previous = scene / journal['stageName']
            assert version(previous) == old_version
            if scenario == 'failed-bootstrap-stale':
                journal.update(state='launching', launchPID=2147483647, launchStart=1, launchDeadline=0)
                record.write_text(json.dumps(journal))
            elif scenario == 'failed-bootstrap-malformed':
                record.write_text('{')
            if scenario == 'corrupted-new':
                (target / 'unexpected-content').write_text('corrupted replacement')
            data = scene / 'isolated-data'
            data.mkdir()
            environment['VANE_DATA_DIR'] = str(data)
            log_path = options.evidence / (scenario + '.log')
            with log_path.open('wb') as log:
                command = [str(sandboxed_helper), '--restart', str(target)] if scenario == 'healthy' or scenario.startswith('failed-bootstrap') else [str(target / 'Contents/MacOS/Vane')]
                process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
                track(work)
                if scenario != 'corrupted-new' and not scenario.startswith('failed-bootstrap'):
                    until(lambda: record.exists() and json.loads(record.read_text())['state'] == 'launching')
                    assert previous.is_dir(), 'Previous bundle must remain before health'
                if scenario in ['failed-bootstrap-stale', 'failed-bootstrap-malformed']:
                    process.wait(timeout=35)
                    assert process.returncode != 0, 'Failed launch must not report success'
                    assert version(target) == new_version and previous.is_dir() and record.exists()
                elif scenario == 'healthy':
                    until(lambda: not record.exists())
                    assert version(target) == new_version and not previous.exists()
                elif scenario == 'crashed-launch':
                    stop(process.pid, work, signal.SIGKILL)  # intentional crash, not cleanup
                    process.wait(timeout=5)
                    process = subprocess.Popen([str(target / 'Contents/MacOS/Vane')], env=environment, stdout=log, stderr=log)
                    track(work)
                    until(lambda: version(target) == old_version and not record.exists())
                    process.wait(timeout=10)
                    until(lambda: any('/Vane.app/Contents/MacOS/Vane' in entry[1] for entry in track(work).values()))
                    assert data.exists()
                else:
                    until(lambda: version(target) == old_version and not record.exists())
                    process.wait(timeout=10)
                    until(lambda: any('/Vane.app/Contents/MacOS/Vane' in entry[1] for entry in track(work).values()))
                if scenario.startswith('failed-bootstrap'):
                    assert (data / 'bootstrap-environment').read_text() == str(data), 'Sandboxed relaunch must preserve isolated environment'
                print(f'PASS: native {scenario}, active version={version(target)}', flush=True)
                for pid in list(track(work)):
                    if '/Vane.app/Contents/MacOS/Vane' in owned[pid][1] and processes(work).get(pid) == owned[pid]:
                        subprocess.run([str(helper), '--quit', str(pid)], check=True)
                        time.sleep(.3)
                    stop(pid, work)
                until(lambda: not track(work), seconds=5)
                if process.poll() is None:
                    process.wait(timeout=5)
                if scenario not in ['failed-bootstrap-stale', 'failed-bootstrap-malformed']:
                    subprocess.run([str(target / 'Contents/MacOS/Vane'), 'browsercheck-cleanup'], env=environment, check=True)
    finally:
        for pid in list(track(work)):
            stop(pid, work)
        time.sleep(.5)
        for pid in list(track(work)):
            stop(pid, work, signal.SIGKILL)
        remaining = track(work)
        (options.evidence / 'processes.json').write_text(json.dumps({'tracked': owned, 'remaining': remaining}, indent=2))
        if remaining:
            raise RuntimeError(f'Task test processes remain: {remaining}')
        container = pathlib.Path.home() / 'Library/Containers' / identifier
        if container.exists():
            # The OS protects container registration and its standard Data scaffold.
            # Clear the fixture's preference domain from its own identity, without
            # traversing managed directories or touching the browser's real container.
            subprocess.run([str(sandboxed_helper), '--cleanup-container'], check=True)
            print('NOTE: macOS retains sandbox registration metadata: ' + str(container), flush=True)
        print('PASS: all tracked native test processes exited; disposable bundles removed', flush=True)
