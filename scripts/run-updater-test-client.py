#!/usr/bin/env python3
"""Record and clean only processes launched from one disposable XPC fixture root."""
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1]).resolve()
assert root.name.startswith('vane-installer-xpc.') and root.parent == pathlib.Path.home() / 'Downloads'
ledger = root / 'processes.json'
tracked = json.loads(ledger.read_text()) if ledger.exists() else {}


def current():
    found = {}
    output = subprocess.check_output(['ps', '-axo', 'pid=,lstart=,command='], text=True)
    for line in output.splitlines():
        match = re.match(r'\s*(\d+)\s+(.{24})\s+(.+)', line)
        if match and match[3].startswith(str(root) + '/') and '/Contents/MacOS/' in match[3]:
            found[match[1]] = [match[2], match[3]]
    return found


def capture():
    for pid, identity in current().items():
        if tracked.get(pid) != identity:
            print(f'TEST PROCESS pid={pid} start={identity[0]} executable={identity[1]}', flush=True)
            tracked[pid] = identity
    ledger.write_text(json.dumps(tracked, indent=2))


if sys.argv[2] == '--cleanup':
    capture()
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        for pid, identity in current().items():
            if identity == tracked.get(pid):  # Validate PID, executable and start before each signal.
                os.kill(int(pid), sig)
        deadline = time.monotonic() + 2
        while current() and time.monotonic() < deadline:
            time.sleep(.1)
        if not current():
            break
    if current():
        raise SystemExit('Task-owned XPC test processes remain')
    print('PASS: tracked XPC test clients/services exited', flush=True)
else:
    assert sys.argv[2] == '--'
    command = sys.argv[3:]
    assert pathlib.Path(command[0]).resolve().is_relative_to(root)
    process = subprocess.Popen(command)
    start = subprocess.check_output(['ps', '-p', str(process.pid), '-o', 'lstart='], text=True).strip()
    tracked[str(process.pid)] = [start, ' '.join(command)]
    print(f'TEST PROCESS pid={process.pid} start={start} executable={command[0]}', flush=True)
    code = process.wait(timeout=60)
    capture()
    print(f'TEST PROCESS exited pid={process.pid} code={code}', flush=True)
    raise SystemExit(code)
