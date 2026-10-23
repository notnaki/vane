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
if not os.environ.get('SIGN_ID'):
    parser.error('SIGN_ID is required for the pinned Developer ID XPC caller/helper authentication')
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


def drain_processes(root):
    # Quitting a browser can start/retire an XPC child after our first snapshot.
    # Keep capturing task-owned identities; never let a confirmation or late child
    # turn cleanup into a false test failure or escape the final cleanup ledger.
    deadline = time.monotonic() + 3
    while track(root) and time.monotonic() < deadline:
        for pid in list(track(root)):
            stop(pid, root)
        time.sleep(.1)
    for pid in list(track(root)):
        stop(pid, root, signal.SIGKILL)
    until(lambda: not track(root), seconds=3)


def launch_recorded(command, environment, log):
    process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
    start = subprocess.check_output(['ps', '-p', str(process.pid), '-o', 'lstart='], text=True).strip()
    owned[process.pid] = (start, ' '.join(command))
    print(f'TEST PROCESS pid={process.pid} start={start} executable={command[0]}', flush=True)
    return process


def until(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if 'work' in globals(): track(work)
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
    identifier = 'io.github.notnaki.vane'
    (driver / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Driver',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1', 'CFBundleName': 'Updater Native Fixture'}))
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Sources/Vane/BundleReplacement.swift'),
                    str(ROOT / 'Sources/Vane/UpdateInstaller.swift'), str(ROOT / 'Sources/Vane/UpdateRelaunch.swift'), str(ROOT / 'Tests/UpdaterNative/main.swift'), '-o', str(helper)], check=True)
    shutil.copy2(helper, sandboxed_helper)
    # Installation runs outside the sandbox, as XPC does. Only restart inherits
    # the browser sandbox, including its shell and signed helper descendants. The
    # driver uses Vane's exact code identity so children retain the same container
    # rights; it runs only transaction/relaunch code, never browser storage code.
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--sign', os.environ.get('SIGN_ID', '-'),
                    '--entitlements', str(ROOT / 'Vane.entitlements'), str(driver)], check=True)
    scenarios = ['healthy', 'fresh-profile', 'retained-healthy', 'crashed-launch', 'corrupted-new', 'legacy-rollback', 'unsupervised-rollback'] + (['failed-bootstrap', 'failed-bootstrap-stale', 'failed-bootstrap-malformed'] if options.bootstrap_failure else [])
    service = driver / 'Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc'
    (service / 'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(ROOT / 'installer/UpdateInstaller-Info.plist', service / 'Contents/Info.plist')
    service_main = work / 'main.swift'
    roots = ', '.join('URL(fileURLWithPath: ' + json.dumps(str(work / name)) + ')' for name in scenarios)
    service_main.write_text((ROOT / 'Sources/UpdateInstaller/main.swift').read_text().replace(
        'let service = InstallerService()', 'let service = InstallerService(applicationsDirectories: [' + roots + '])'))
    service_source = work / 'FixtureService.swift'
    service_source.write_text((ROOT / 'Sources/UpdateInstaller/InstallerService.swift').read_text().replace(
        'try worker.run()', 'if let directory = isolatedDirectory { let logURL = URL(fileURLWithPath: directory).appendingPathComponent("worker.log"); FileManager.default.createFile(atPath: logURL.path, contents: nil); worker.standardError = try FileHandle(forWritingTo: logURL) }; try worker.run()'))
    sources = ['Sources/Vane/BundleReplacement.swift' , 'Sources/Vane/UpdateVersion.swift', 'Sources/Vane/UpdateInstaller.swift',
               'Sources/Vane/UpdateRelaunch.swift', 'Sources/UpdateInstaller/UpdateInstallation.swift',
               'Sources/UpdateInstaller/InstallerRelaunch.swift']
    subprocess.run(['xcrun', 'swiftc', '-O'] + [str(ROOT / name) for name in sources]
                   + [str(service_source), str(service_main), '-o', str(service / 'Contents/MacOS/VaneUpdateInstaller')], check=True)
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--sign', os.environ.get('SIGN_ID', '-'), str(service)], check=True)
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--sign', os.environ.get('SIGN_ID', '-'),
                    '--entitlements', str(ROOT / 'Vane.entitlements'), str(driver)], check=True)
    templates = {}
    for kind, original in [('old', options.previous), ('new', options.app)]:
        app = work / (kind + '.app')
        shutil.copytree(original.resolve(), app, symlinks=True)
        if kind == 'new':
            # Bootstrap and health now contact the candidate's own XPC service. Inject
            # fixture roots into that helper too; a browser request cannot widen roots.
            candidate_service = app / 'Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc'
            shutil.rmtree(candidate_service)
            shutil.copytree(service, candidate_service)
            subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp',
                            '--entitlements', str(ROOT / 'Vane.entitlements'), '--sign', os.environ['SIGN_ID'], str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
        templates[kind] = app
    old_version, new_version = version(templates['old']), version(templates['new'])
    if options.bootstrap_failure:
        identity = os.environ.get('SIGN_ID')
        assert identity, 'SIGN_ID is required for the bootstrap failure fixture'
        stub = work / 'stub.app'
        shutil.copytree(templates['new'], stub, symlinks=True)
        source_code = work / 'stub.c'
        probe_report = work / 'probe-processes.jsonl'
        probe_format = '{"pid":%d,"startSeconds":%llu,"startMicroseconds":%llu,"executable":"%s"}\n'
        source_code.write_text('#include <stdlib.h>\n#include <stdio.h>\n#include <unistd.h>\n#include <libproc.h>\n#include <sys/proc_info.h>\n'
            + 'int main(void) { struct proc_bsdinfo info={0}; proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&info,sizeof(info)); char executable[4096]={0}; proc_pidpath(getpid(),executable,sizeof(executable)); FILE *report=fopen('
            + json.dumps(str(probe_report)) + ',"a"); if(report) { fprintf(report,' + json.dumps(probe_format)
            + ',getpid(),(unsigned long long)info.pbi_start_tvsec,(unsigned long long)info.pbi_start_tvusec,executable); fclose(report); } '
            + 'const char *d=getenv("VANE_DATA_DIR"); if(d) { char p[4096]; snprintf(p,sizeof(p),"%s/bootstrap-environment",d); FILE *f=fopen(p,"w"); if(f) { fputs(d,f); fclose(f); } } return 1; }\n')
        subprocess.run(['xcrun', 'clang', str(source_code), '-o', str(stub / 'Contents/MacOS/Vane')], check=True)
        subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--entitlements', str(ROOT / 'Vane.entitlements'), '--sign', identity, str(stub)], check=True)
        templates['stub'] = stub
    environment = {key: os.environ[key] for key in ['HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG'] if key in os.environ}
    try:
        for scenario in scenarios:
            scene = work / scenario
            scene.mkdir()
            target = scene / 'Vane.app'
            shutil.copytree(templates['old'], target, symlinks=True)
            subprocess.run([str(helper), str(templates['stub'] if scenario.startswith('failed-bootstrap') else templates['new']), str(target)], check=True)
            record = scene / '.Vane.app.vane-transaction.json'
            journal = json.loads(record.read_text())
            previous = scene / journal['stageName']
            assert version(previous) == old_version
            if scenario == 'retained-healthy':
                journal.update(state='healthy', launchPID=2147483647, launchStart=1)
                record.write_text(json.dumps(journal))
            elif scenario == 'legacy-rollback':
                for key in ['targetPath', 'volumeID', 'newDigest', 'oldDigest']:
                    journal.pop(key, None)
                journal.update(state='launching', launchPID=2147483647, launchStart=1, launchDeadline=0)
                record.write_text(json.dumps(journal))
            elif scenario == 'failed-bootstrap-stale':
                journal.update(state='launching', launchPID=2147483647, launchStart=1, launchDeadline=0)
                record.write_text(json.dumps(journal))
            elif scenario == 'failed-bootstrap-malformed':
                record.write_text('{')
            if scenario in ['corrupted-new', 'unsupervised-rollback']:
                (target / 'unexpected-content').write_text('corrupted replacement')
            data = scene / 'isolated-data'
            data.mkdir()
            environment['VANE_DATA_DIR'] = str(data)
            log_path = options.evidence / (scenario + '.log')
            with log_path.open('wb') as log:
                # Exercise upgrading an established installation, including its completed
                # welcome state. The unchanged v0.0.34 release has a separate first-run
                # resource lookup bug; an upgrade must not become a fresh installation.
                if scenario != 'fresh-profile':
                    preparation = launch_recorded([str(sandboxed_helper), '--prepare-upgrade-data', str(data)], environment, log)
                    assert preparation.wait(timeout=10) == 0
                restart_worker = [str(target / 'Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc/Contents/MacOS/VaneUpdateInstaller'), '--relaunch', str(target)]
                command = [str(sandboxed_helper), '--restart', str(target)] if scenario == 'healthy' else ([str(target / 'Contents/MacOS/Vane')] if scenario == 'unsupervised-rollback' else restart_worker)
                process = launch_recorded(command, environment, log)
                # Record this exact child directly before any global process inventory.
                # Translocation lookups for unrelated apps can block the inventory and
                # leave an exited driver unreaped past the worker's uncertainty deadline.
                if scenario == 'healthy':
                    process.wait(timeout=10)  # Reap the exited requesting parent before launch.
                    assert process.returncode == 0
                track(work)
                if scenario not in ['retained-healthy', 'corrupted-new', 'legacy-rollback', 'unsupervised-rollback'] and not scenario.startswith('failed-bootstrap'):
                    until(lambda: record.exists() and json.loads(record.read_text())['state'] == 'launching')
                    assert previous.is_dir(), 'Previous bundle must remain before health'
                if scenario in ['failed-bootstrap-stale', 'failed-bootstrap-malformed']:
                    process.wait(timeout=35)
                    assert process.returncode != 0, 'Failed launch must not report success'
                    assert version(target) == new_version and previous.is_dir() and record.exists()
                elif scenario == 'unsupervised-rollback':
                    process.wait(timeout=20)
                    assert process.returncode != 0, 'Unsupervised isolated rollback must request manual reopen'
                    assert version(target) == old_version and not record.exists()
                    assert not any('/Vane.app/Contents/MacOS/Vane' in entry[1] for entry in track(work).values())
                    process = launch_recorded([str(target / 'Contents/MacOS/Vane')], environment, log)
                    until(lambda: (data / 'vane.db').exists())
                elif scenario in ['healthy', 'fresh-profile', 'retained-healthy']:
                    until(lambda: not record.exists(), seconds=60)
                    assert version(target) == new_version and not previous.exists()
                    if scenario == 'retained-healthy':
                        # Recovery of the earlier healthy launch precedes this
                        # process's database bootstrap; still require real storage.
                        until(lambda: (data / 'vane.db').exists())
                    assert (data / 'vane.db').exists(), 'XPC worker must preserve isolated browser storage'
                elif scenario == 'crashed-launch':
                    children = [pid for pid, entry in track(work).items() if '/Vane.app/Contents/MacOS/Vane' in entry[1]]
                    assert len(children) == 1
                    stop(children[0], work, signal.SIGKILL)  # intentional crash, not cleanup
                    process.wait(timeout=5)
                    assert process.returncode != 0
                    process = launch_recorded(restart_worker, environment, log)
                    track(work)
                    until(lambda: version(target) == old_version and not record.exists())
                    process.wait(timeout=10)
                    assert process.returncode == 0, 'Supervised restoration must return success'
                    until(lambda: any('/Vane.app/Contents/MacOS/Vane' in entry[1] for entry in track(work).values()))
                    assert process.returncode == 0, 'Supervised rollback must complete successfully'
                else:
                    until(lambda: version(target) == old_version and not record.exists())
                    process.wait(timeout=10)
                    assert process.returncode == 0, 'Supervised restoration must return success'
                    until(lambda: any('/Vane.app/Contents/MacOS/Vane' in entry[1] for entry in track(work).values()))
                if scenario.startswith('failed-bootstrap') and scenario != 'failed-bootstrap-malformed':
                    assert (data / 'bootstrap-environment').read_text() == str(data), 'Sandboxed relaunch must preserve isolated environment'
                if scenario not in ['failed-bootstrap-stale', 'failed-bootstrap-malformed']:
                    until(lambda: (data / 'vane.db').exists())
                    mains = [(pid, identity) for pid, identity in track(work).items()
                             if '/Vane.app/Contents/MacOS/Vane' in identity[1]]
                    assert len(mains) == 1, 'Exactly one disposable browser may own this profile'
                    pid, identity = mains[0]
                    # A database can precede a fatal startup/resource failure. Require
                    # the same executable/start identity to survive the rest of bootstrap.
                    time.sleep(2)
                    assert processes(work).get(pid) == identity, 'Restored/healthy browser exited during bootstrap'
                    # Inspect only a proven task-owned process; never print its full environment.
                    actual = subprocess.check_output(['ps', 'eww', '-p', str(pid), '-o', 'command='], text=True)
                    assert re.search(r'(?:^| )VANE_DATA_DIR=' + re.escape(str(data)) + r'(?: |$)', actual), 'Actual restored/healthy process lost isolated environment'
                    report = {'pid': pid, 'start': identity[0], 'executable': identity[1], 'isolatedDirectory': str(data)}
                    (options.evidence / (scenario + '-environment.json')).write_text(json.dumps(report, indent=2))
                print(f'PASS: native {scenario}, active version={version(target)}', flush=True)
                for pid in list(track(work)):
                    if '/Vane.app/Contents/MacOS/Vane' in owned[pid][1] and processes(work).get(pid) == owned[pid]:
                        subprocess.run([str(helper), '--quit', str(pid)], check=True)
                        time.sleep(.3)
                    stop(pid, work)
                drain_processes(work)
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
        for scene in scenarios:
            worker_log = work / scene / 'isolated-data/worker.log'
            if worker_log.exists(): shutil.copy2(worker_log, options.evidence / (scene + '-worker.log'))
        probe_report = work / 'probe-processes.jsonl'
        if probe_report.exists(): shutil.copy2(probe_report, options.evidence / 'probe-processes.jsonl')
        (options.evidence / 'processes.json').write_text(json.dumps({'tracked': owned, 'remaining': remaining}, indent=2))
        if remaining:
            raise RuntimeError(f'Task test processes remain: {remaining}')
        print('PASS: all tracked native test processes exited; disposable bundles removed', flush=True)
