#!/usr/bin/env python3
"""Reuse a full PR native suite only for an identical, current-base squash tree."""
from collections import Counter
from datetime import datetime
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlencode

WORKFLOW = '.github/workflows/checks.yml'
REQUIRED_JOBS = {
    'Change scope and diff checks', 'CI routing fixtures',
    'Source fixtures', 'Shared debug build', 'Packaging and integrations', 'checks',
    *(f'Native regressions ({index}/4)' for index in range(1, 5)),
}


def api(endpoint, *, paginate=False):
    command = ['gh', 'api', endpoint]
    if paginate:
        command += ['--paginate', '--slurp']
    return json.loads(subprocess.check_output(command, text=True, timeout=20))


def pages(endpoint, field=None):
    result = api(endpoint, paginate=True)
    return [item for page in result for item in (page[field] if field else page)]


def git(*args):
    return subprocess.check_output(['git', *args], text=True, timeout=10).strip()


def timestamp(value):
    return datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')


def verified_run():
    env = os.environ
    if env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REF') != 'refs/heads/main':
        return None
    repo, sha, before = (env.get(key, '') for key in ('GITHUB_REPOSITORY', 'GITHUB_SHA', 'BASE_SHA'))
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo) or not all(
            re.fullmatch(r'[0-9a-f]{40}', value) and value != '0' * 40 for value in (sha, before)):
        return None
    # Multi-commit pushes and merge commits fall back. The previous target must be
    # exactly the squash parent, not merely an ancestor somewhere in its history.
    if git('show', '-s', '--format=%P', sha) != before:
        return None
    tree = git('rev-parse', sha + '^{tree}')
    prefix = f'repos/{repo}/'
    candidates = [pr for pr in pages(prefix + f'commits/{sha}/pulls?per_page=100')
                  if pr['state'] == 'closed' and pr['merged_at']
                  and pr['merge_commit_sha'] == sha and pr['base']['ref'] == 'main'
                  and pr['base']['repo']['full_name'] == repo
                  and pr['head']['repo']['full_name'] == repo]
    if len(candidates) != 1:
        return None
    pr = candidates[0]
    # Closed PRs disappear from run.pull_requests. Instead, bind the source branch
    # to exactly one PR across *all* states and reject every recorded base change.
    # A run from another target (or before this PR existed) must never qualify.
    query = urlencode({'state': 'all', 'head': repo.split('/')[0] + ':' + pr['head']['ref'], 'per_page': 100})
    branch_prs = pages(prefix + 'pulls?' + query)
    if len(branch_prs) != 1 or branch_prs[0]['number'] != pr['number']:
        return None
    timeline = pages(prefix + f'issues/{pr["number"]}/timeline?per_page=100')
    if any(item['event'] in ('base_ref_changed', 'automatic_base_change_succeeded') for item in timeline):
        return None
    head = pr['head']['sha']
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        return None
    commit = api(prefix + f'commits/{head}')
    if commit['sha'] != head or commit['commit']['tree']['sha'] != tree:
        return None
    comparison = api(prefix + f'compare/{before}...{head}')
    if comparison['status'] not in ('ahead', 'identical') or comparison['merge_base_commit']['sha'] != before:
        return None
    # The head contains the prior target. Its PR merge ref therefore had the same
    # tree too; a passing suite for a stale or unrelated integration cannot qualify.
    current_id = str(int(env['GITHUB_RUN_ID']))
    workflow_id = api(prefix + f'actions/runs/{current_id}')['workflow_id']
    runs = pages(prefix + f'actions/workflows/{workflow_id}/runs?event=pull_request&head_sha={head}&per_page=100',
                 'workflow_runs')
    latest = max(runs, key=lambda run: run['id'], default=None)
    if latest is None:
        return None
    # Fetch current metadata as well as the listing: never fall back to an older
    # successful run or an earlier attempt when the latest one is not successful.
    run = api(prefix + f'actions/runs/{int(latest["id"])}')
    if (run['id'] != latest['id'] or run['workflow_id'] != workflow_id or run['path'] != WORKFLOW
            or run['event'] != 'pull_request' or run['head_sha'] != head
            or run['head_branch'] != pr['head']['ref'] or run['head_repository']['full_name'] != repo
            or run['status'] != 'completed' or run['conclusion'] != 'success'
            or not timestamp(pr['created_at']) <= timestamp(run['created_at'])
            <= timestamp(run['updated_at']) <= timestamp(pr['merged_at'])):
        return None
    attempt = int(run['run_attempt'])
    if attempt < 1:
        return None
    jobs = pages(prefix + f'actions/runs/{run["id"]}/attempts/{attempt}/jobs?per_page=100', 'jobs')
    counts = Counter(job['name'] for job in jobs)
    if any(counts[name] != 1 for name in REQUIRED_JOBS):
        return None
    if any(job['status'] != 'completed' or job['conclusion'] != 'success'
           or job['run_attempt'] != attempt for job in jobs if job['name'] in REQUIRED_JOBS):
        return None
    if api(prefix + f'actions/runs/{run["id"]}') != run:
        return None
    return run['id']


def find_reusable_run():
    try:
        return verified_run()
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Native reuse unavailable ({type(error).__name__}); running the full native suite.', file=sys.stderr)
        return None


def main():
    run_id = find_reusable_run()
    value = 'native_reused=' + str(run_id is not None).lower()
    print(value)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(value + '\n')
    if run_id is None:
        message = 'No verified identical PR tree; running the full native suite.'
    else:
        repo = os.environ['GITHUB_REPOSITORY']
        message = (f'Reusing all four native shards from [PR run {run_id}]'
                   f'(https://github.com/{repo}/actions/runs/{run_id}): identical full tree, '
                   'current target included, latest full suite passed before merge. '
                   'Main build, packaging/integrations, source and routing fixtures still run.')
    print(message)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(message + '\n')


if __name__ == '__main__':
    main()
