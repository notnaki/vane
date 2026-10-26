#!/usr/bin/env python3
"""Attest loaded Apple Safari-engine images after the unchanged UA checks pass."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = "/System/Cryptexes/App/System/Library/StagedFrameworks/Safari"
CORE = {"WebKit", "WebCore", "JavaScriptCore"}


def validate_image_record(text):
    lines = [line.removeprefix("UA ENGINE IMAGES ") for line in text.splitlines() if line.startswith("UA ENGINE IMAGES ")]
    if len(lines) != 1:
        raise ValueError("Exactly one loaded-engine record is required per launch")
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValueError("Malformed loaded-engine record") from error
    if not isinstance(record, dict) or record.get("hardenedRuntime") is not True or not isinstance(record.get("images"), list):
        raise ValueError("The actual launch must attest Hardened Runtime and loaded images")
    images = {}
    for image in record["images"]:
        if not isinstance(image, dict) or not isinstance(image.get("path"), str):
            raise ValueError("Malformed engine image")
        path = Path(image["path"])
        if path.name not in CORE:
            continue
        if (path.name in images or not path.resolve().is_relative_to(Path(ROOT).resolve())
                or not any(parent.name == path.name + ".framework" for parent in path.parents)):
            raise ValueError("Missing, duplicate or mixed system/staged core engine")
        if not re.fullmatch(r"625\.\d+\.\d+", str(image.get("version", ""))):
            raise ValueError("Actual core image did not use the Safari 27 engine family")
        try:
            identity = uuid.UUID(image["uuid"])
            if identity.int == 0:
                raise ValueError("Nil image UUID")
        except (KeyError, ValueError, TypeError, AttributeError) as error:
            raise ValueError("Actual image UUID is required") from error
        images[path.name] = image
    if set(images) != CORE:
        raise ValueError("All three staged core engine images must be observed")
    return images


def check_cohort(directory):
    cache = {}
    for number in range(1, 9):
        log = directory / f"trial-{number:02d}" / "primary.log"
        images = validate_image_record(log.read_text(errors="replace"))
        for image in images.values():
            path = Path(image["path"])
            if str(path) not in cache:
                framework = next(parent for parent in path.parents if parent.name == path.name + ".framework")
                subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple", str(framework)],
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(path)], check=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
                cache[str(path)] = {str(uuid.UUID(value)) for value in re.findall(r"UUID: ([0-9A-Fa-f-]{36})", result.stdout)}
            if str(uuid.UUID(image["uuid"])) not in cache[str(path)]:
                raise ValueError("Loaded engine UUID does not match its Apple-signed installed image")
    print("PASS staged WebKit evidence: 8 Hardened Runtime launches; Apple-signed WebKit/WebCore/JavaScriptCore image UUIDs match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    try:
        check_cohort(parser.parse_args().directory)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL staged WebKit evidence: {error}", file=sys.stderr)
        sys.exit(1)
