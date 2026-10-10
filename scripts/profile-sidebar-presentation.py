#!/usr/bin/env python3
"""Run the opt-in sidebar diagnostic as a visible, isolated native release app.

Requires a logged-in macOS desktop and Xcode's SwiftPM build backend. Timings are
diagnostics, never CI assertions. A shared lock serializes local profiling windows.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
LOCK = Path('/tmp/vane-performance-window.lock')


def competing_work(owned_pid=None):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,stat=,comm='], text=True).splitlines()
    for row in rows:
        pid, state, command = row.strip().split(maxsplit=2)
        if state.startswith('T') or int(pid) == owned_pid:
            continue
        if any(name in command for name in ('swift-frontend', 'swift-test', '/xctest',
                                             'VanePerformance', 'VaneSidebarProfile')):
            return True
        if ('/tmp/' in command or '/.codex/worktrees/' in command) and '/Contents/MacOS/' in command:
            return True
    return False


def build(output):
    with (output / 'build.log').open('w') as log:
        subprocess.run(['swift', 'test', '-c', 'release', '-Xswiftc', '-enable-testing',
                        '-j', '2', '--filter', 'SidebarPresentationPerformanceTests'],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    source = (ROOT / 'Tests/VaneTests/SidebarPresentationPerformanceTests.swift').read_text()
    source = source.replace('import XCTest\n', '').replace(
        'SidebarPresentationPerformanceTests: XCTestCase', 'SidebarPresentationProbe')
    source = source.replace('TestEnvironment.prepare()', 'SidebarProbeEnvironment.prepare()')
    source += '''
@MainActor var probeFailures = 0
@MainActor func XCTSkipUnless(_ condition: Bool, _ message: String = "") throws {
    if !condition { throw NSError(domain: "DiagnosticPrerequisite", code: 1) }
}
@MainActor func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "MissingFixtureValue", code: 1) }; return value
}
@MainActor func XCTFail(_ message: String) { probeFailures += 1; print("FIXTURE_FAILURE", message) }
@MainActor func XCTAssertTrue(_ value: Bool, _ message: String = "") { if !value { XCTFail(message) } }
@MainActor func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") {
    if a != b { XCTFail("\\(a) != \\(b) \\(message)") }
}
@MainActor enum SidebarProbeEnvironment {
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VANE_SIDEBAR_DATA_DIR"]!)
    static func prepare() {
        setenv("VANE_DATA_DIR", directory.path, 1)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("SIDEBAR_FIXTURE_DIR", directory.path)
    }
    static func cleanup() {
        UserDefaults.dropScratchSuite(UserDefaults.suiteName(forDataDir: directory.path))
        try? FileManager.default.removeItem(at: directory)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
Task { @MainActor in
    do { try await SidebarPresentationProbe().testPopulatedSidebarPresentation() }
    catch { probeFailures += 1; print("FIXTURE_ERROR", error) }
    SidebarProbeEnvironment.cleanup()
    exit(probeFailures == 0 ? 0 : 1)
}
app.run()
'''
    probe = output / 'Probe.swift'
    probe.write_text(source)
    objects = sorted((ROOT / '.build/out/Intermediates.noindex/Vane.build/Release').glob(
        f'vane-*-testable-t.build/Objects-normal/{platform.machine()}/*.o'))
    if not objects:
        raise RuntimeError('No Xcode SwiftPM release testable objects; see build.log')
    app = output / 'Vane Sidebar Profile.app'
    executable = app / 'Contents/MacOS/VaneSidebarProfile'
    executable.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'io.github.notnaki.vane.sidebarprofile.' + uuid.uuid4().hex,
        'CFBundleExecutable': executable.name, 'CFBundleName': 'Vane Sidebar Profile',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True,
    }))
    # SwiftPM renames the executable entry point in its testable objects (vane_main),
    # so linking main.o here does not run the production bootstrap.
    subprocess.run(['swiftc', '-O', '-enable-testing', '-I', str(ROOT / '.build/out/Products/Release'),
                    str(probe), *map(str, objects), '-framework', 'AppKit', '-framework',
                    'WebKit', '-lsqlite3', '-o', str(executable)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    return executable


def suite_for(directory):
    value = 5381
    for byte in str(directory).encode():
        value = (value * 33 + byte) & ((1 << 64) - 1)
    digits, encoded = '0123456789abcdefghijklmnopqrstuvwxyz', ''
    while value:
        encoded = digits[value % 36] + encoded
        value //= 36
    return 'vane.datadir.' + (encoded or '0')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    parser.add_argument('--interactive', type=int, choices=(20, 300), help='Leave fixture open for four minutes')
    parser.add_argument('--app', type=Path, help='Reuse a diagnostic app built by this script')
    parser.add_argument('--lock-timeout', type=float, default=600, help='Maximum seconds to wait for another profiler')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    data = output / ('data-' + uuid.uuid4().hex)
    owner = 'sidebar presentation diagnostic ' + str(output)
    acquired, process = False, None
    try:
        print('Waiting for the shared profiling window.', flush=True)
        deadline = time.monotonic() + args.lock_timeout
        while not acquired:
            try:
                LOCK.mkdir(); acquired = True
                (LOCK / 'owner').write_text(owner + '\n')
            except FileExistsError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f'Profiling lock still held: {LOCK}. Inspect its owner before removing a stale lock.')
                time.sleep(1)
        executable = (args.app.resolve() / 'Contents/MacOS/VaneSidebarProfile') if args.app else build(output)
        quiet_since = None
        print('Waiting for 30 continuous seconds without competing builds or fixtures.', flush=True)
        while quiet_since is None or time.monotonic() - quiet_since < 30:
            if competing_work(): quiet_since = None
            elif quiet_since is None: quiet_since = time.monotonic()
            time.sleep(1)
        env = os.environ.copy()
        for key in ('VANE_SIDEBAR_PREFLIGHT', 'VANE_SIDEBAR_REALIZATION_CHECK', 'VANE_SIDEBAR_INTERACTIVE'):
            env.pop(key, None)
        env.update(VANE_UI_PERFORMANCE='1', VANE_SIDEBAR_DATA_DIR=str(data))
        if args.interactive: env['VANE_SIDEBAR_INTERACTIVE'] = str(args.interactive)
        contaminated = False
        with (output / 'metrics.log').open('w') as log:
            power_start = subprocess.check_output(['pmset', '-g', 'batt'], text=True)
            log.write(power_start); log.flush()
            process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT)
            started = subprocess.run(['ps', '-p', str(process.pid), '-o', 'lstart='],
                                     text=True, capture_output=True).stdout.strip()
            identity = {'pid': process.pid, 'start': started, 'executable': str(executable),
                        'bundle': str(executable.parents[2]), 'data': str(data),
                        'sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
            (output / 'instance.json').write_text(json.dumps(identity, indent=2))
            print(json.dumps(identity), flush=True)
            while process.poll() is None:
                contaminated |= competing_work(process.pid)
                time.sleep(1)
        power_end = subprocess.check_output(['pmset', '-g', 'batt'], text=True)
        power_changed = power_start.splitlines()[0] != power_end.splitlines()[0]
        (output / 'validity.json').write_text(json.dumps({
            'exit': process.returncode, 'competing_work_detected': contaminated,
            'interactive': args.interactive, 'power_start': power_start, 'power_end': power_end,
            'power_source_changed': power_changed,
        }, indent=2))
        print((output / 'metrics.log').read_text(), flush=True)
        if contaminated: raise RuntimeError('Competing workload detected: discard these timings and rerun')
        if power_changed: raise RuntimeError('Power source changed: discard these timings and rerun')
        if process.returncode: raise RuntimeError('Fixture failed; see metrics.log')
    finally:
        # An unreaped child cannot have its PID reused. Stop only this owned launch.
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if process is not None:
            subprocess.run(['defaults', 'delete', suite_for(data)], capture_output=True)
            shutil.rmtree(data, ignore_errors=True)
            print(f'Test process exited: pid={process.pid} code={process.returncode}', flush=True)
        if acquired:
            owner_file = LOCK / 'owner'
            if owner_file.exists() and owner_file.read_text().strip() == owner:
                owner_file.unlink(); LOCK.rmdir()
            elif not owner_file.exists():
                LOCK.rmdir()


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    main()
