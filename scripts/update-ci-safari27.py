#!/usr/bin/env python3
"""Install only Apple's stable Safari 27 update on a disposable macOS 26 runner.

This does not bundle WebKit, change Vane's deployment floor, install macOS upgrades,
or reboot a runner. Fresh probe launches must still attest their loaded engine.
"""
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys


def require_hosted_macos26(environment, version):
    expected = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}
    if any(environment.get(key) != value for key, value in expected.items()) or not re.fullmatch(r"26(?:\.\d+)*", version):
        raise ValueError("Safari installation is restricted to disposable GitHub-hosted macOS 26 runners")


def select_safari_update(catalog):
    candidates = []
    for label in re.findall(r"^\s*\*\s+Label:\s*([^\r\n]+)$", catalog, re.MULTILINE):
        match = re.fullmatch(r"Safari(27(?:\.\d+)*)TahoeAuto-(27(?:\.\d+)*)", label)
        if match and match[1] == match[2]:
            candidates.append((tuple(map(int, match[1].split("."))), label))
    if not candidates or len({label for _, label in candidates}) != len(candidates):
        raise ValueError("No unambiguous stable Safari 27 update for macOS Tahoe was listed; no update installed")
    return max(candidates)[1]


def require_updated_engine(safari, webkit):
    if not re.fullmatch(r"27(?:\.\d+)*", safari) or not re.fullmatch(r"21625(?:\.\d+)+", webkit):
        raise ValueError(f"Safari 27 and its macOS 26 system WebKit were not activated: Safari={safari}, WebKit={webkit}; a newer runner image or restart may be required")


def installed_versions():
    with Path("/Applications/Safari.app/Contents/Info.plist").open("rb") as handle:
        safari = plistlib.load(handle)["CFBundleShortVersionString"]
    with Path("/System/Library/Frameworks/WebKit.framework/Resources/Info.plist").open("rb") as handle:
        webkit = plistlib.load(handle)["CFBundleVersion"]
    return safari, webkit


def main():
    require_hosted_macos26(os.environ, platform.mac_ver()[0])
    before = installed_versions()
    print(json.dumps({"phase": "before", "OS": platform.mac_ver()[0], "Safari": before[0], "WebKit": before[1]}), flush=True)
    try:
        require_updated_engine(*before)
        print("Safari 27 system engine already installed; no mutation needed", flush=True)
        return 0
    except ValueError:
        pass
    scan = subprocess.run(["/usr/sbin/softwareupdate", "--list"], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=180)
    print(scan.stdout, flush=True)
    scan.check_returncode()
    label = select_safari_update(scan.stdout)
    print(f"Installing exactly one Apple update: {label}", flush=True)
    subprocess.run(["sudo", "/usr/sbin/softwareupdate", "--install", label, "--verbose"], check=True, timeout=600)
    after = installed_versions()
    print(json.dumps({"phase": "after", "OS": platform.mac_ver()[0], "Safari": after[0], "WebKit": after[1]}), flush=True)
    require_updated_engine(*after)
    print("Safari 27/macOS 26 disk postcondition satisfied; actual loaded-engine and UA checks still required", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL Safari 27 CI setup: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
