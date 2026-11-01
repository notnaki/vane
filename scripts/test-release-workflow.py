#!/usr/bin/env python3
"""Exercise release credentials, tags, and publication with disposable fixtures."""

import json
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
    return command(["/bin/bash", "-c", body], cwd, environment, succeeds)


def test_publication(temporary):
    # Run the real publish step; replace only the GitHub network boundary.
    binaries = temporary / "bin"
    binaries.mkdir()
    gh = binaries / "gh"
    gh.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["GH_CALLS"]).open("a") as calls:
    calls.write(json.dumps(args) + "\\n")
if args[:2] == ["release", "view"]:
    sys.exit(0 if os.environ["GH_RELEASE_EXISTS"] == "true" else 1)
sys.exit(1 if args[1] == os.environ.get("GH_FAIL_COMMAND") else 0)
''')
    gh.chmod(0o755)
    for tag, prerelease, latest in (
        ("v0.0.38", "false", []),
        ("v0.0.39-nightly.20261101.9001", "true", ["--latest=false"]),
    ):
        for exists in (False, True):
            for failure in (None, "upload", "edit") if exists else (None, "create"):
                calls = temporary / "gh-calls.jsonl"
                calls.write_text("")
                environment = {**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}",
                               "TAG": tag, "GH_CALLS": str(calls),
                               "GH_RELEASE_EXISTS": str(exists).lower(),
                               "GH_FAIL_COMMAND": failure or ""}
                run_step("Publish", temporary, environment, succeeds=failure is None)
                expected = [["release", "view", tag]]
                if exists:
                    expected.append(["release", "upload", tag, "Vane.dmg", "Vane.zip", "--clobber"])
                    if failure != "upload":
                        expected.append(["release", "edit", tag, f"--prerelease={prerelease}", *latest])
                else:
                    expected.append(["release", "create", tag, "Vane.dmg", "Vane.zip",
                                     "--verify-tag", "--generate-notes", f"--prerelease={prerelease}", *latest])
                assert [json.loads(line) for line in calls.read_text().splitlines()] == expected


def tag_from_environment(path):
    values = [line.removeprefix("TAG=") for line in path.read_text().splitlines()
              if line.startswith("TAG=")]
    assert len(values) == 1, values
    return values[0]


def main():
    assert "concurrency:\n  group: release\n  queue: max\n" in WORKFLOW.read_text()
    assert "schedule:" in WORKFLOW.read_text(), "Nightlies need a daily schedule"
    assert "options: [stable, nightly]" in WORKFLOW.read_text()
    assert "needs: prepare" in WORKFLOW.read_text()
    assert "if: needs.prepare.outputs.publish == 'true'" in WORKFLOW.read_text()
    names = [line.strip() for line in LINES if line.startswith("      - name: ")]
    assert names.index("- name: Require public release credentials") < names.index("- name: Pick the tag")
    assert names.index("- name: Notarize + staple the app") < names.index("- name: Package")
    assert names.index("- name: Package") < names.index("- name: Publish validated tag")
    assert names.index("- name: Publish validated tag") < names.index("- name: Publish")
    publish_section, _ = step("Publish validated tag")
    assert "        if: github.event_name != 'push'" in publish_section
    _, publish = step("Publish")
    assert '--latest=false' in publish, "Prereleases must not replace the stable download"

    keys = ("CERT_B64", "CERT_PW", "KEY_ID", "ISSUER_ID", "KEY_B64")
    with tempfile.TemporaryDirectory(prefix="vane-release-test-") as directory:
        temporary = Path(directory)
        test_publication(temporary)
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

        nightly = "v0.0.19-nightly.20261031.9003"
        nightly_env = {**environment, "GITHUB_RUN_ID": "9003", "NIGHTLY_TAG": nightly}
        run_step("Pick the tag", source, nightly_env, event="schedule")
        assert command(["git", "rev-list", "-n", "1", nightly], source) == sha
        assert command(["git", "tag", "--list", nightly], remote) == ""
        run_step("Publish validated tag", source, {**nightly_env, "TAG": nightly}, event="schedule")
        assert command(["git", "tag", "--list", nightly], remote) == nightly
        # Publication retries retain the prepared nightly tag, not a new stable patch.
        run_step("Pick the tag", source, nightly_env, event="schedule")
        command(["git", "tag", "-f", "-a", nightly, "-m", "wrong source"], source)
        command(["git", "commit", "--allow-empty", "-m", "another revision"], source)
        command(["git", "tag", "-f", "-a", nightly, "-m", "wrong source"], source)
        run_step("Pick the tag", source, nightly_env, event="schedule", succeeds=False)

    print("PASS: credentials fail closed; stable/nightly publication arguments and failures; tags publish after packaging; reruns preserve version/source")


if __name__ == "__main__":
    main()
