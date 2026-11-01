import json
import os
from pathlib import Path
import subprocess
import time

REPO = os.environ['GITHUB_REPOSITORY']
FIX = 'da269e027b77a23bbfdc38b09132f515e8c3c4df'
DEADLINE = time.monotonic() + 3300


def api(path, payload=None):
    args = ['gh', 'api', f'repos/{REPO}/{path}']
    if payload is not None:
        args += ['--method', 'POST', '--input', '-']
    result = subprocess.check_output(args, text=True,
                                     input=json.dumps(payload) if payload is not None else None)
    return json.loads(result) if result.strip() else None


def finish(message):
    print(message, flush=True)
    Path(os.environ['GITHUB_STEP_SUMMARY']).write_text(message + '\n')


last = None
while time.monotonic() < DEADLINE:
    sha = api('git/ref/heads/main')['object']['sha']
    if sha != FIX:
        comparison = api(f'compare/{FIX}...{sha}')
        if comparison['status'] not in ('ahead', 'identical'):
            raise RuntimeError('Main no longer contains the requested fix; nightly not dispatched')
    runs = api(f'actions/workflows/checks.yml/runs?head_sha={sha}&branch=main&event=push&per_page=100')['workflow_runs']
    check = max(runs, key=lambda run: run['id'], default={})
    state = (sha, check.get('status'), check.get('conclusion'))
    if state != last:
        print(f'Main CI: {state}', flush=True)
        last = state
    if check.get('status') != 'completed':
        time.sleep(30)
        continue
    if check.get('conclusion') != 'success':
        raise RuntimeError(f'Main CI did not pass: {check.get("html_url")}; nightly not dispatched')
    if api('git/ref/heads/main')['object']['sha'] != sha:
        continue

    endpoint = 'actions/workflows/release.yml/runs?branch=main&event=workflow_dispatch&per_page=30'
    previous = {run['id'] for run in api(endpoint)['workflow_runs']}
    api('actions/workflows/release.yml/dispatches', {'ref': 'main', 'inputs': {'channel': 'nightly'}})
    print(f'Nightly dispatch accepted after successful main CI at {sha}', flush=True)
    release = None
    for _ in range(20):
        new = [run for run in api(endpoint)['workflow_runs'] if run['id'] not in previous]
        if new:
            # The queue's GITHUB_TOKEN dispatch is distinct from manual user runs.
            bot = [run for run in new if run.get('actor', {}).get('login') == 'github-actions[bot]']
            release = min(bot or new, key=lambda run: run['id'])
            break
        time.sleep(5)
    if release is None:
        raise RuntimeError('Nightly was dispatched; inspect the release workflow for its run')
    print(f'Nightly workflow: {release["html_url"]}', flush=True)
    if release['head_sha'] != sha:
        # Main advanced between the eligibility check and dispatch. Its own
        # prepare gate safely skips unvalidated revisions; wait for the new CI.
        time.sleep(30)
        continue
    while time.monotonic() < DEADLINE:
        jobs = api(f'actions/runs/{release["id"]}/jobs?per_page=100')['jobs']
        publishing = next((job for job in jobs if job['name'] == 'release'), None)
        if publishing and publishing['conclusion'] != 'skipped':
            if publishing['conclusion'] in ('failure', 'cancelled', 'timed_out'):
                raise RuntimeError(f'Nightly failed: {release["html_url"]}')
            finish(f'Nightly is queued on GitHub: {release["html_url"]}\n\nChecked source: `{sha}`; includes PR #577.')
            raise SystemExit(0)
        run = api(f'actions/runs/{release["id"]}')
        if run['status'] == 'completed':
            if publishing and publishing['conclusion'] == 'skipped':
                finish(f'Nightly workflow safely skipped publication (already published or eligibility changed): {release["html_url"]}')
                raise SystemExit(0)
            raise RuntimeError(f'Nightly preparation failed: {release["html_url"]}')
        time.sleep(10)
raise RuntimeError('Timed out waiting for checked main and the nightly publication job')
