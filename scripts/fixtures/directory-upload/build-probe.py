#!/usr/bin/env python3
"""Build a uniquely identified, ad hoc signed standalone WKWebView probe."""
import plistlib
import subprocess
import tempfile
import uuid
from pathlib import Path

fixture = Path(__file__).resolve().parent
root = fixture.parents[2]
app = Path(tempfile.mkdtemp(prefix='vane-directory-probe-')) / 'DirectoryProbe.app'
executable = app / 'Contents/MacOS/probe'
executable.parent.mkdir(parents=True)
subprocess.run(['swiftc', '-swift-version', '6', str(fixture / 'Probe.swift'), '-o', str(executable),
                '-framework', 'AppKit', '-framework', 'WebKit'], check=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'io.github.notnaki.directoryprobe.' + uuid.uuid4().hex,
    'CFBundleExecutable': 'probe', 'CFBundleName': 'Directory probe',
    'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
}))
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(root / 'Vane.entitlements'),
                str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(executable)
