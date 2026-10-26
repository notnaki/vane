#!/usr/bin/env python3
"""Validate the diff and conservatively select documentation-only CI."""
import argparse
import os
from pathlib import PurePosixPath
import subprocess
import sys


def documentation(path):
    parts = PurePosixPath(path).parts
    return path.endswith(".md") and (
        len(parts) == 1 or parts[0] == "docs" or
        path.startswith(".github/ISSUE_TEMPLATE/") or path == ".github/pull_request_template.md"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()
    refs = (args.base, args.head)
    known = all(ref and set(ref) != {"0"} and subprocess.run(
        ["git", "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 for ref in refs)
    app_required = True
    if known:
        # Disable rename detection so both old source and new Markdown paths count.
        result = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", *refs, "--"],
                                check=True, capture_output=True)
        paths = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
        app_required = not paths or not all(documentation(path) for path in paths)
        subprocess.run(["git", "diff", "--check", *refs, "--"], check=True)
        print(f"Validated {len(paths)} changed paths", file=sys.stderr)
    else:
        print("Missing comparison history: requiring all app checks", file=sys.stderr)
    value = "app_required=" + str(app_required).lower()
    print(value)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(value + "\n")


if __name__ == "__main__":
    main()
