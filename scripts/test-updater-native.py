#!/usr/bin/env python3
"""Disposable AppKit launch/rollback tests. Coordinate a native slot first.

Uses signed disposable copies and VANE_DATA_DIR under Downloads. Relaunch explicitly
propagates isolation and creates a new instance. The previous app is an unchanged
signed release. Native candidate notarization is simulated by the transaction driver;
real distribution checks run separately through test-update-installer.
"""
import argparse
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


def processes(root):
    output = subprocess.check_output(['ps', '-axo', 'pid=,lstart=,command='], text=True)
    result = {}
    for line in output.splitlines():
        match = re.match(r'\s*(\d+)\s+(.{24})\s+(.+)', line)
        if match and str(root) in match[3] and ('/Contents/MacOS/' in match[3] or '/bin/sh -c' in match[3] or str(root / 'install') in match[3]):
            pid, start, command = int(match[1]), match[2], match[3]
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
    helper = work / 'install'
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Sources/Vane/BundleReplacement.swift'),
                    str(ROOT / 'Sources/Vane/UpdateInstaller.swift'), str(ROOT / 'Sources/Vane/UpdateRelaunch.swift'), str(ROOT / 'Tests/UpdaterNative/main.swift'), '-o', str(helper)], check=True)
    # Match the production sandboxed parent -> shell -> signed helper chain.
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'io.github.notnaki.vane.UpdaterNative',
                    '--entitlements', str(ROOT / 'Vane.entitlements'), str(helper)], check=True)
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
        source_code.write_text('int main(void) { return 1; }\n')
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
            environment['VANE_DATA_DIR'] = str(data)
            log_path = options.evidence / (scenario + '.log')
            with log_path.open('wb') as log:
                command = [str(helper), '--restart', str(target)] if scenario.startswith('failed-bootstrap') else [str(target / 'Contents/MacOS/Vane')]
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
        print('PASS: all tracked native test processes exited; disposable bundles removed', flush=True)
