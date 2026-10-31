#!/usr/bin/env python3
"""Select a changed, checked main revision before exposing release credentials."""
import json
import os
import re
import subprocess

STABLE = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
NIGHTLY = re.compile(r"v\d+\.\d+\.\d+-nightly\.\d+\.\d+")


def prepare(*, sha, ref, run_id, date, runs, releases, tags, markers, tag_commit):
    if ref != "refs/heads/main":
        raise ValueError("Nightly releases must run from main")
    checks = [run for run in runs if run.get("head_sha") == sha
              and run.get("head_branch") == "main" and run.get("event") == "push"]
    latest = max(checks, key=lambda run: run["id"], default={})
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        return None

    reused = [tag for tag, marker in markers.items()
              if marker == f"vane-release-run:{run_id}" and NIGHTLY.fullmatch(tag)]
    if len(reused) > 1:
        raise ValueError("Multiple nightly tags belong to this workflow run")
    if reused:
        if tag_commit(reused[0]) != sha:
            raise ValueError("The run's nightly tag points to a different commit")
        return reused[0]

    for release in releases:
        tag = release.get("tag_name", "")
        if not release.get("draft", True) and release.get("prerelease") and NIGHTLY.fullmatch(tag):
            if tag_commit(tag) == sha:
                return None

    versions = [tuple(map(int, match.groups())) for tag in tags if (match := STABLE.fullmatch(tag))]
    major, minor, patch = max(versions, default=(0, 0, 0))
    if not re.fullmatch(r"\d{8}", date) or not re.fullmatch(r"[1-9]\d*", run_id):
        raise ValueError("Invalid nightly date or workflow run ID")
    tag = f"v{major}.{minor}.{patch + 1}-nightly.{date}.{run_id}"
    if tag in tags:
        raise ValueError("The prepared nightly tag already exists")
    return tag


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    env = os.environ
    if env["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Nightly releases must run from main")
    repo, sha = env["GITHUB_REPOSITORY"], env["GITHUB_SHA"]
    runs = json.loads(command("gh", "api", f"repos/{repo}/actions/workflows/checks.yml/runs?head_sha={sha}&branch=main&event=push&per_page=100"))
    releases = json.loads(command("gh", "api", f"repos/{repo}/releases?per_page=100"))
    run = json.loads(command("gh", "api", f"repos/{repo}/actions/runs/{env['GITHUB_RUN_ID']}"))
    markers = dict(line.split("\t", 1) for line in command("git", "for-each-ref",
                   "--format=%(refname:short)%09%(contents:subject)", "refs/tags").splitlines())
    tag = prepare(sha=sha, ref=env["GITHUB_REF"], run_id=env["GITHUB_RUN_ID"],
                  date=run["created_at"][:10].replace("-", ""), runs=runs["workflow_runs"],
                  releases=releases, tags=list(markers), markers=markers,
                  tag_commit=lambda tag: command("git", "rev-list", "-n", "1", tag))
    with open(env["GITHUB_OUTPUT"], "a") as output:
        output.write(f"publish={'true' if tag else 'false'}\n")
        if tag:
            output.write(f"tag={tag}\n")
    print(f"Nightly eligible: {tag} at {sha}" if tag else
          "Skipping nightly: main is unchanged or its latest checks have not passed")


if __name__ == "__main__":
    main()
