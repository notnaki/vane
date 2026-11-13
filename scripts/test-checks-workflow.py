#!/usr/bin/env python3
"""Exercise docs-aware gating, one-build fan-out, and isolated native coverage."""
import itertools
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/checks.yml'


def jobs(text):
    body = text.split('\njobs:\n', 1)[1]
    starts = list(re.finditer(r'^  ([a-z][a-z0-9-]*):\n', body, re.MULTILINE))
    return {match[1]: body[match.end():starts[index + 1].start() if index + 1 < len(starts) else len(body)]
            for index, match in enumerate(starts)}


def block(section):
    lines = section.splitlines()
    start = lines.index('        run: |') + 1
    end = next((index for index in range(start, len(lines))
                if lines[index].strip() and not lines[index].startswith('          ')), len(lines))
    return '\n'.join(line[10:] for line in lines[start:end])


def dependencies(section):
    match = re.search(r'^    needs: \[([^\]]+)\]$', section, re.MULTILINE)
    return set(match[1].replace(' ', '').split(',')) if match else set()


def verify_gate_cases(script, cases, keys):
    # Keep each invocation in a fresh subshell, including its own errexit state.
    # Feed Bash on stdin so thousands of cases do not hit argv size limits.
    commands = ["set +e", "gate() (", script, ")"]
    for environment, _ in cases:
        commands.extend(f"export {key}={shlex.quote(environment[key])}" if key in environment
                        else f"unset {key}" for key in keys)
        # Calling outside an if/|| is essential: those contexts disable errexit.
        commands.extend(["gate >/dev/null 2>&1", "printf '%s\\n' \"$?\""])
    result = subprocess.run(["bash"], input="\n".join(commands) + "\n",
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    statuses = result.stdout.splitlines()
    assert len(statuses) == len(cases), (len(statuses), len(cases), result.stderr)
    for status, (environment, wanted) in zip(statuses, cases):
        assert (status == "0") == wanted, (environment, status, wanted)


def main():
    text = WORKFLOW.read_text()
    sections = jobs(text)
    gate = sections['checks']
    assert re.search(r'^    if: \$\{\{ always\(\) \}\}$', gate, re.MULTILINE)
    assert dependencies(gate) == set(sections) - {'checks', 'prune-caches'}
    bindings = dict(re.findall(r'^          ([A-Z_]+): \$\{\{ needs\.([a-z-]+)\.result \}\}$', gate, re.MULTILINE))
    assert set(bindings.values()) == dependencies(gate)
    assert 'continue-on-error:' not in text
    assert 'known-limitations' not in sections
    assert 'scripts/classify-worker-ua.py ' not in text
    assert '--suite required' in sections['native']
    assert "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT: '90'" in sections['native']
    preflight = sections['native'].split('- name: Owned AppKit loop preflight', 1)[1].split('- name: Native regression tests', 1)[0]
    assert 'timeout-minutes: 4' in preflight
    assert 'AppKit loop smoke: delayedHeartbeat=true, completed=true' in preflight
    assert 'APP_REQUIRED: ${{ needs.changes.outputs.app_required }}' in gate
    script = block(gate)
    verify_gate_cases("set -euo pipefail\nfalse\nexit 0", [({}, False)], [])
    verify_gate_cases('set -euo pipefail\n[ "$VALUE" = expected ]', [
        ({'VALUE': 'expected'}, True), ({'VALUE': '$(exit 0)'}, False), ({}, False),
    ], ['VALUE'])
    cases = []
    # Preserve every original full/cheap case, then exhaust the new main-reuse
    # path. Invalid reuse contexts are rejected independently of job outcomes.
    for app, reused, event in (('true', 'false', 'pull_request'),
                               ('false', 'false', 'pull_request'), ('true', 'true', 'push')):
        for states in itertools.product(('success', 'failure', 'cancelled', 'skipped'), repeat=len(bindings)):
            results = dict(zip(bindings.values(), states))
            reuse_allowed = reused == 'false' or (app == 'true' and event == 'push')
            wanted = reuse_allowed and results['changes'] == results['routing'] == 'success' and all(
                value == ('skipped' if app == 'false' or name == 'native' and reused == 'true' else 'success')
                for name, value in results.items() if name not in ('changes', 'routing'))
            env = {**dict(zip(bindings, states)), 'APP_REQUIRED': app, 'NATIVE_REUSED': reused,
                   'EVENT_NAME': event, 'EVENT_REF': 'refs/heads/main' if event == 'push' else 'refs/pull/7/merge'}
            cases.append((env, wanted))
    baseline = {**dict.fromkeys(bindings, 'success'), 'APP_REQUIRED': 'true',
                'NATIVE_REUSED': 'false', 'EVENT_NAME': 'push', 'EVENT_REF': 'refs/heads/main'}
    for key in [*bindings, 'APP_REQUIRED', 'NATIVE_REUSED']:
        for value in ('', 'unknown', 'success\nsuccess', '$(exit 0)'):
            env = {**baseline, key: value}
            cases.append((env, False))
        env = dict(baseline)
        env.pop(key)
        cases.append((env, False))
    for event, ref in (('pull_request', 'refs/pull/7/merge'), ('pull_request', 'refs/heads/main'),
                       ('push', 'refs/heads/other'), ('workflow_dispatch', 'refs/heads/main')):
        cases.append(({**baseline, 'NATIVE_REUSED': 'true', 'NATIVE_RESULT': 'skipped',
                       'EVENT_NAME': event, 'EVENT_REF': ref}, False))
    cases.append(({**baseline, 'APP_REQUIRED': 'false', 'NATIVE_REUSED': 'true',
                   'SOURCE_RESULT': 'skipped', 'BUILD_RESULT': 'skipped',
                   'NATIVE_RESULT': 'skipped', 'PACKAGING_RESULT': 'skipped'}, False))
    verify_gate_cases(script, cases, [*bindings, 'APP_REQUIRED', 'NATIVE_REUSED', 'EVENT_NAME', 'EVENT_REF'])
    trials = len(cases)

    assert 'runs-on: ubuntu-latest' in sections['changes']
    assert 'fetch-depth: 0' in sections['changes']
    assert 'scripts/ci-change-scope.py' in sections['changes']
    assert 'native_reused: ${{ steps.reuse.outputs.native_reused || \'false\' }}' in sections['changes']
    assert 'scripts/ci-native-reuse.py' in sections['changes']
    assert 'actions: read' in sections['changes'] and 'pull-requests: read' in sections['changes']
    assert 'runs-on: ubuntu-latest' in sections['routing']
    assert not dependencies(sections['routing']), 'routing fixtures run alongside scope detection'
    for command in ('python3 scripts/test-ci-native-reuse.py', 'python3 scripts/test-ci-change-scope.py', 'python3 scripts/test-checks-workflow.py'):
        assert command in sections['routing'], command + ' must also validate the fast path'
    for name in ('source', 'build', 'native', 'packaging'):
        section = sections[name]
        assert "if: needs.changes.outputs.app_required == 'true'" in section
        assert dependencies(section) == ({'changes', 'build'} if name in ('native', 'packaging') else {'changes'})
    build, native, packaging = (sections[name] for name in ('build', 'native', 'packaging'))
    assert "needs.changes.outputs.native_reused != 'true'" in native
    assert all('native_reused' not in sections[name] for name in ('build', 'source', 'packaging'))
    header = text.split('\njobs:\n', 1)[0]
    assert "group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}" in header
    assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in header
    assert '--build-system' not in build + native + packaging, 'build and skip-build consumers must use the same toolchain default'
    assert 'swift build -c debug --build-tests --disable-index-store' in build
    assert 'BIN_PATH=$(swift build -c debug --show-bin-path)' in build
    assert 'run: ./make-app.sh debug --skip-app-build\n' in build
    assert 'VANE_CI_TOOLCHAIN_KEY: ${{ steps.toolchain.outputs.key }}' in build
    assert 'uses: actions/cache/restore@v6' in build and 'uses: actions/cache/save@v6' in build
    assert "github.event_name == 'push' && github.ref == 'refs/heads/main'" in build
    assert "hashFiles('Sources/**', 'Tests/**', 'scripts/ci-source-state.py', 'make-app.sh', '.github/workflows/checks.yml')" in build
    assert 'key: swift-debug-v3-' in build
    assert '            swift-debug-v2-' in build, 'old caches remain a migration fallback'
    assert 'node docs/tests/galaxy.test.cjs' not in text, 'website fixtures belong to the website branch'
    for command in ('python3 scripts/test-ci-change-scope.py', 'python3 scripts/test-checks-workflow.py'):
        assert text.count(command) == 1, command + ' must run once for every scope'
    assert 'scripts/ci-build-artifact.py pack' in build
    assert 'name: debug-runtime' in build and 'compression-level: 0' in build
    for section in (native, packaging):
        assert 'uses: actions/download-artifact@v8' in section
        assert 'digest-mismatch: warn' in section
        assert 'name: debug-runtime' in section
        assert 'scripts/ci-build-artifact.py restore' in section
        assert 'swift build' not in section
        assert 'actions/cache/' not in section
        assert './make-app.sh' not in section
    assert 'secrets.' not in build + native + packaging
    assert "fail-fast: ${{ github.event_name == 'pull_request' }}" in native
    assert 'shard: [1, 2, 3, 4]' in native
    assert '--index "$NATIVE_SHARD" --count 4' in native
    assert 'NATIVE_SHARD: ${{ matrix.shard }}' in native
    assert 'swift test list --skip-build' in native
    assert 'scripts/native-test-shards.py plan' in native
    assert 'scripts/run-native-tests.py --skip-build --jobs 1' in native
    assert 'scripts/native-test-shards.py verify' in native
    assert 'name: native-loop-logs-${{ matrix.shard }}' in native
    assert "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT: '1200'" in native
    assert "VANE_APPKIT_LOOP_SMOKE: '1'" in native
    assert 'Native suite primary status=0; cleanup status=0' in native
    assert native.index('Owned AppKit loop preflight') < native.index('Native regression tests')
    assert 'Preserve native loop failure evidence\n        if: ${{ always() }}' in native
    for command in ('python3 scripts/test-ci-source-state.py',
                    'python3 scripts/test-native-fixture-runner.py', './.build/debug/vane selfcheck --pure',
                    'scripts/check-webkit-startup.sh', 'scripts/check-app-icons.sh'):
        assert text.count('run: ' + command) == 1, command + ' must run once in app jobs'
    for fixture in ('test-native-test-shards.py', 'test-ci-build-artifact.py',
                    'test-classify-worker-ua.py'):
        assert fixture in sections['source']
    assert '--key swift-debug- ' in sections['prune-caches'], 'prune old cache generations too'
    assert dependencies(sections['prune-caches']) == {'changes', 'checks'}
    assert "needs.changes.outputs.app_required == 'true'" in sections['prune-caches']
    print(f'PASS: {trials} gate cases; docs skips and one-build fan-out preserve failures and native coverage')


if __name__ == '__main__':
    main()
