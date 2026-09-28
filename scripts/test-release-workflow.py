#!/usr/bin/env python3
"""Exercise release credential and tag steps against a disposable Git remote."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
LINES = WORKFLOW.read_text().splitlines()


def step(name):
    start = LINES.index(f"      - name: {name}")
    end = next((index for index in range(start + 1, len(LINES))
                if LINES[index].startswith("      - name: ")), len(LINES))
    section = LINES[start:end]
    run = section.index("        run: |") + 1
    body = [line[10:] if line.startswith("          ") else ""
            for line in section[run:]]
    return section, "\n".join(body)


def command(args, cwd, env=None, succeeds=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert (result.returncode == 0) == succeeds, (args, result.stdout)
    return result.stdout.strip()


def run_step(name, cwd, environment, succeeds=True, event="workflow_dispatch"):
    _, body = step(name)
    body = body.replace("${{ github.event_name }}", event)
    return command(["bash", "-c", body], cwd, environment, succeeds)


def tag_from_environment(path):
    values = [line.removeprefix("TAG=") for line in path.read_text().splitlines()
              if line.startswith("TAG=")]
    assert len(values) == 1, values
    return values[0]


def main():
    names = [line.strip() for line in LINES if line.startswith("      - name: ")]
    assert names.index("- name: Require public release credentials") < names.index("- name: Pick the tag")
    assert names.index("- name: Notarize + staple the app") < names.index("- name: Package")
    assert names.index("- name: Package") < names.index("- name: Publish validated tag")
    assert names.index("- name: Publish validated tag") < names.index("- name: Publish")
    publish_section, _ = step("Publish validated tag")
    assert "        if: github.event_name == 'workflow_dispatch'" in publish_section

    keys = ("CERT_B64", "CERT_PW", "KEY_ID", "ISSUER_ID", "KEY_B64")
    with tempfile.TemporaryDirectory(prefix="vane-release-test-") as directory:
        temporary = Path(directory)
        remote = temporary / "remote.git"
        source = temporary / "source"
        command(["git", "init", "--bare", str(remote)], temporary)
        source.mkdir()
        command(["git", "init", str(source)], temporary)
        command(["git", "config", "user.name", "Fixture"], source)
        command(["git", "config", "user.email", "fixture@example.invalid"], source)
        command(["git", "commit", "--allow-empty", "-m", "fixture"], source)
        command(["git", "branch", "-M", "main"], source)
        command(["git", "remote", "add", "origin", str(remote)], source)
        command(["git", "tag", "v0.0.16"], source)
        command(["git", "push", "origin", "main", "v0.0.16"], source)

        for missing in (None, *keys):
            credentials = {key: "fixture" for key in keys if key != missing}
            if missing is None:
                credentials = {}
            run_step("Require public release credentials", source,
                     {**os.environ, **credentials}, succeeds=False)
        run_step("Require public release credentials", source,
                 {**os.environ, **dict.fromkeys(keys, "fixture")})

        sha = command(["git", "rev-parse", "HEAD"], source)
        def pick(run_id, attempt):
            environment_file = temporary / f"env-{run_id}-{attempt}"
            environment_file.touch()
            environment = {**os.environ, "BUMP": "patch", "GITHUB_RUN_ID": run_id,
                           "GITHUB_RUN_ATTEMPT": str(attempt), "GITHUB_SHA": sha,
                           "GITHUB_ENV": str(environment_file), "GITHUB_REF_NAME": "main"}
            run_step("Pick the tag", source, environment)
            return tag_from_environment(environment_file), environment

        first, environment = pick("9001", 1)
        assert first == "v0.0.17", first
        assert command(["git", "tag", "--list", first], remote) == "", "tag pushed before packaging"
        run_step("Publish validated tag", source, {**environment, "TAG": first})
        assert command(["git", "tag", "--list", first], remote) == first

        retry, retry_environment = pick("9001", 2)
        assert retry == first, (first, retry)
        run_step("Publish validated tag", source, {**retry_environment, "TAG": retry})
        assert command(["git", "tag", "--list", "v0.0.18"], remote) == ""
        next_tag, _ = pick("9002", 1)
        assert next_tag == "v0.0.18", next_tag
        assert command(["git", "tag", "--list", next_tag], remote) == "", "tag pushed before packaging"

    print("PASS: credentials fail closed; tags publish after packaging; reruns reuse their tag")


if __name__ == "__main__":
    main()
