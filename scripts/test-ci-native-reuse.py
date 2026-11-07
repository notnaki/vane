#!/usr/bin/env python3
"""Exercise native-result reuse with real git trees and a fake GitHub boundary."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class ReuseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / 'scripts/ci-native-reuse.py'
        assert path.exists(), 'Missing exact-tree native validation reuse'
        spec = importlib.util.spec_from_file_location('native_reuse', path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.root / 'source').write_text('before\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        (self.root / 'source').write_text('after\n')
        self.git('commit', '-qam', 'PR head')
        self.head = self.git('rev-parse', 'HEAD')
        self.tree = self.git('rev-parse', 'HEAD^{tree}')
        # A squash commit has a different SHA but the same tree as its PR head.
        self.sha = self.git('commit-tree', self.tree, '-p', self.base, '-m', 'squash')
        self.env = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main',
                    'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_SHA': self.sha,
                    'GITHUB_RUN_ID': '200', 'BASE_SHA': self.base}
        self.pr = {'number': 7, 'state': 'closed', 'merged_at': '2026-11-07T10:00:00Z',
                   'merge_commit_sha': self.sha,
                   'base': {'ref': 'main', 'repo': {'full_name': 'owner/repo'}},
                   'head': {'sha': self.head, 'ref': 'feature',
                            'repo': {'full_name': 'owner/repo'}}}
        self.run = {'id': 100, 'workflow_id': 9, 'path': '.github/workflows/checks.yml',
                    'event': 'pull_request', 'head_sha': self.head, 'head_branch': 'feature',
                    'head_repository': {'full_name': 'owner/repo'}, 'run_attempt': 1,
                    'status': 'completed', 'conclusion': 'success',
                    'created_at': '2026-11-07T09:00:00Z',
                    'updated_at': '2026-11-07T09:15:00Z'}
        self.jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success', 'run_attempt': 1}
                     for name in ('Change scope and diff checks', 'Website and routing fixtures',
                                  'Source fixtures', 'Shared debug build',
                                  'Native regressions (1/4)', 'Native regressions (2/4)',
                                  'Native regressions (3/4)', 'Native regressions (4/4)',
                                  'Packaging and integrations', 'checks')]
        self.data = {
            f'commits/{self.sha}/pulls?per_page=100': [self.pr],
            f'commits/{self.head}': {'sha': self.head, 'commit': {'tree': {'sha': self.tree}}},
            f'compare/{self.base}...{self.head}': {
                'status': 'ahead', 'merge_base_commit': {'sha': self.base}},
            'actions/runs/200': {'workflow_id': 9},
            'actions/runs/100': self.run,
            f'actions/workflows/9/runs?event=pull_request&head_sha={self.head}&per_page=100':
                {'workflow_runs': [self.run]},
            'actions/runs/100/attempts/1/jobs?per_page=100': {'jobs': self.jobs},
        }

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def api(self, endpoint, *, paginate=False):
        prefix = 'repos/owner/repo/'
        assert endpoint.startswith(prefix), endpoint
        value = self.data[endpoint[len(prefix):]]
        # --paginate --slurp yields pages, even for one page.
        return [copy.deepcopy(value)] if paginate else copy.deepcopy(value)

    def decide(self):
        previous = os.getcwd()
        try:
            os.chdir(self.root)
            with patch.dict(os.environ, self.env, clear=True), \
                    patch.object(self.module, 'api', side_effect=self.api):
                return self.module.find_reusable_run()
        finally:
            os.chdir(previous)

    def test_identical_squash_tree_reuses_successful_full_pr_run(self):
        self.assertNotEqual(self.sha, self.head)
        self.assertEqual(self.decide(), 100)

    def test_other_events_and_refs_never_reuse(self):
        for key, value in (('GITHUB_EVENT_NAME', 'pull_request'),
                           ('GITHUB_EVENT_NAME', 'workflow_dispatch'),
                           ('GITHUB_REF', 'refs/heads/feature'), ('BASE_SHA', '0' * 40)):
            with self.subTest(key=key, value=value):
                original = self.env[key]
                self.env[key] = value
                self.assertIsNone(self.decide())
                self.env[key] = original

    def test_changed_tree_or_current_base_runs_native_again(self):
        for endpoint, value in (
            (f'commits/{self.head}', {'sha': self.head, 'commit': {'tree': {'sha': 'a' * 40}}}),
            (f'compare/{self.base}...{self.head}',
             {'status': 'diverged', 'merge_base_commit': {'sha': 'a' * 40}}),
        ):
            with self.subTest(endpoint=endpoint):
                original = self.data[endpoint]
                self.data[endpoint] = value
                self.assertIsNone(self.decide())
                self.data[endpoint] = original
        self.env['BASE_SHA'] = self.head
        self.assertIsNone(self.decide())

    def test_merge_commits_do_not_qualify_as_single_squash_pushes(self):
        merge = self.git('commit-tree', self.tree, '-p', self.base, '-p', self.head, '-m', 'merge')
        self.env['GITHUB_SHA'] = merge
        self.assertIsNone(self.decide())

    def test_only_the_merged_same_repository_main_pr_qualifies(self):
        for path, value in ((('state',), 'open'), (('merged_at',), None),
                            (('merge_commit_sha',), self.head), (('base', 'ref'), 'other'),
                            (('base', 'repo', 'full_name'), 'other/repo'),
                            (('head', 'repo', 'full_name'), 'fork/repo')):
            with self.subTest(path=path):
                target = self.pr
                for part in path[:-1]:
                    target = target[part]
                original = target[path[-1]]
                target[path[-1]] = value
                self.assertIsNone(self.decide())
                target[path[-1]] = original

    def test_unrelated_or_incomplete_run_never_grants_reuse(self):
        for field, value in (('workflow_id', 8), ('path', '.github/workflows/other.yml'),
                             ('event', 'push'), ('head_sha', self.base),
                             ('head_branch', 'other'), ('head_repository', {'full_name': 'fork/repo'}),
                             ('status', 'in_progress'), ('conclusion', 'failure'),
                             ('updated_at', '2026-11-07T10:01:00Z')):
            with self.subTest(field=field):
                original = self.run[field]
                self.run[field] = value
                self.assertIsNone(self.decide())
                self.run[field] = original

    def test_latest_run_and_attempt_cannot_hide_a_failure(self):
        endpoint = f'actions/workflows/9/runs?event=pull_request&head_sha={self.head}&per_page=100'
        newer = {**self.run, 'id': 101, 'conclusion': 'failure'}
        self.data['actions/runs/101'] = newer
        self.data[endpoint]['workflow_runs'] = [self.run, newer]
        self.assertIsNone(self.decide())
        self.data[endpoint]['workflow_runs'] = [self.run]
        self.run['run_attempt'] = 2
        self.data['actions/runs/100/attempts/2/jobs?per_page=100'] = {
            'jobs': [dict(job, run_attempt=2) for job in self.jobs]}
        self.assertEqual(self.decide(), 100)
        self.data['actions/runs/100/attempts/2/jobs?per_page=100']['jobs'][-1]['conclusion'] = 'failure'
        self.assertIsNone(self.decide())

    def test_every_full_suite_job_must_pass_in_the_same_attempt(self):
        for index in range(len(self.jobs)):
            for field, value in (('conclusion', 'failure'), ('conclusion', 'skipped'),
                                 ('conclusion', 'cancelled'), ('status', 'in_progress'),
                                 ('run_attempt', 2)):
                with self.subTest(job=self.jobs[index]['name'], field=field, value=value):
                    original = self.jobs[index][field]
                    self.jobs[index][field] = value
                    self.assertIsNone(self.decide())
                    self.jobs[index][field] = original
        removed = self.jobs.pop(4)
        self.assertIsNone(self.decide())
        self.jobs.append(removed)
        self.jobs.append(dict(removed, conclusion='failure'))
        self.assertIsNone(self.decide())

    def test_all_pages_of_jobs_are_validated(self):
        original = self.api
        def pages(endpoint, *, paginate=False):
            if '/jobs?' in endpoint:
                assert paginate
                return [{'jobs': self.jobs[:5]}, {'jobs': self.jobs[5:]}]
            return original(endpoint, paginate=paginate)
        with patch.object(self, 'api', side_effect=pages):
            self.assertEqual(self.decide(), 100)
            self.jobs[-1]['conclusion'] = 'failure'
            self.assertIsNone(self.decide())

    def test_all_pages_of_runs_and_prs_are_considered(self):
        original = self.api
        def pages(endpoint, *, paginate=False):
            if '/pulls?' in endpoint:
                assert paginate
                return [[], [self.pr]]
            if '/runs?event=' in endpoint:
                assert paginate
                return [{'workflow_runs': []}, {'workflow_runs': [self.run]}]
            return original(endpoint, paginate=paginate)
        with patch.object(self, 'api', side_effect=pages):
            self.assertEqual(self.decide(), 100)

    def test_api_errors_malformed_evidence_and_rerun_races_fall_back(self):
        original = self.api
        for replacement in ({}, None, 'malformed'):
            with self.subTest(replacement=replacement), patch.object(
                    self, 'api', return_value=replacement):
                self.assertIsNone(self.decide())
        with patch.object(self, 'api', side_effect=subprocess.TimeoutExpired('gh', 20)):
            self.assertIsNone(self.decide())
        reads = 0
        def racing(endpoint, *, paginate=False):
            nonlocal reads
            value = original(endpoint, paginate=paginate)
            if endpoint.endswith('/actions/runs/100'):
                reads += 1
                if reads == 2:
                    value['status'] = 'in_progress'
                    value['run_attempt'] = 2
            return value
        with patch.object(self, 'api', side_effect=racing):
            self.assertIsNone(self.decide())

    def test_cli_falls_back_on_api_errors_and_records_its_decision(self):
        # Exercise the executable/output boundary with a real git repository and gh stub.
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        gh = bin_dir / 'gh'
        gh.write_text('#!/bin/sh\nexit 1\n')
        gh.chmod(0o755)
        output = self.root / 'output'
        summary = self.root / 'summary'
        result = subprocess.run(['python3', str(ROOT / 'scripts/ci-native-reuse.py')],
                                cwd=self.root, capture_output=True, text=True,
                                env={**os.environ, **self.env, 'PATH': str(bin_dir) + ':' + os.environ['PATH'],
                                     'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), 'native_reused=false\n')
        self.assertIn('full native suite', summary.read_text())

    def test_cli_records_true_and_the_verified_source_run_link(self):
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        fixture = self.root / 'github.json'
        fixture.write_text(json.dumps(self.data))
        gh = bin_dir / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['API_FIXTURE']) as source:
    data = json.load(source)
value = data[sys.argv[2].removeprefix('repos/owner/repo/')]
print(json.dumps([value] if '--slurp' in sys.argv else value))
''')
        gh.chmod(0o755)
        output, summary = self.root / 'output', self.root / 'summary'
        result = subprocess.run(['python3', str(ROOT / 'scripts/ci-native-reuse.py')],
                                cwd=self.root, capture_output=True, text=True,
                                env={**os.environ, **self.env, 'PATH': str(bin_dir) + ':' + os.environ['PATH'],
                                     'API_FIXTURE': str(fixture), 'GITHUB_OUTPUT': str(output),
                                     'GITHUB_STEP_SUMMARY': str(summary)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), 'native_reused=true\n')
        self.assertIn('https://github.com/owner/repo/actions/runs/100', summary.read_text())


if __name__ == '__main__':
    unittest.main()
