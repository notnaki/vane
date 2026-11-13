#!/usr/bin/env python3
"""Validate the diff and conservatively select cheap CI checks."""
import argparse
import os
import re
from pathlib import PurePosixPath
import subprocess
import sys


ROUTING_FILES = {"scripts/ci-change-scope.py", "scripts/test-ci-change-scope.py",
                 "scripts/test-checks-workflow.py"}
WORKFLOW = ".github/workflows/checks.yml"
WEBSITE_FILES = {"docs/.nojekyll", "docs/CNAME", "docs/robots.txt", "docs/sitemap.xml",
                 "scripts/check-site-rendering.swift", "docs/versions/galaxy-v2/VERSION.txt",
                 "docs/versions/liquid-v3/VERSION.txt"}
WEBSITE_SUFFIXES = {".html", ".css", ".js", ".cjs", ".svg", ".png", ".jpg", ".jpeg",
                    ".webp", ".gif", ".ico", ".woff", ".woff2", ".ttf", ".mp4", ".webm"}


def routing_only_workflow_change(base, head):
    """Routing can use its own fixtures; changes to app jobs still build the app."""
    versions = []
    headers = []
    for ref in (base, head):
        result = subprocess.run(["git", "show", f"{ref}:{WORKFLOW}"], capture_output=True)
        if result.returncode != 0:
            return False
        text = result.stdout.decode("utf-8")
        if "\njobs:\n" not in text:
            return False
        header, body = text.split("\njobs:\n", 1)
        headers.append(header)
        starts = list(re.finditer(r"^  ([a-z][a-z0-9-]*):\n", body, re.MULTILINE))
        jobs = {match[1]: body[match.end():starts[i + 1].start() if i + 1 < len(starts) else len(body)]
                for i, match in enumerate(starts)}
        if not {"changes", "checks", "source", "build", "native", "packaging", "prune-caches"} <= jobs.keys():
            return False
        versions.append(jobs)
    before, after = versions
    return headers[0] == headers[1] and before.keys() == after.keys() and all(
        before[name] == after[name] for name in before if name not in {"changes", "checks", "routing"})


def cheap_checks_only(path):
    parts = PurePosixPath(path).parts
    if path in ROUTING_FILES or path in WEBSITE_FILES:
        return True
    if parts and parts[0] == "docs" and PurePosixPath(path).suffix in WEBSITE_SUFFIXES:
        return True
    if parts[:2] == ("docs", "fonts") and len(parts) == 3 and (
            parts[2] == "OFL.txt" or parts[2].endswith("-OFL.txt")):
        return True
    return path == ".gitignore" or path.endswith(".md") and (
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
        # A PR event can retain an older target SHA while checkout supplies a
        # newer integration merge. Compare that merge with its actual target,
        # only after authenticating both the merge and PR source parents.
        base, head = refs
        if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
            parents = subprocess.check_output(
                ["git", "rev-list", "--parents", "-n", "1", "--end-of-options", head],
                text=True).split()
            if (len(parents) == 3 and parents[0] == os.environ.get("GITHUB_SHA")
                    and parents[2] == os.environ.get("PR_HEAD_SHA")):
                base = parents[1]
                print(f"Comparing PR integration with actual target {base}", file=sys.stderr)
        refs = (base, head)
        # Disable rename detection so both old and new paths count.
        result = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", *refs, "--"],
                                check=True, capture_output=True)
        paths = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
        app_required = not paths or not all(
            cheap_checks_only(path) or path == WORKFLOW and routing_only_workflow_change(*refs)
            for path in paths)
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
