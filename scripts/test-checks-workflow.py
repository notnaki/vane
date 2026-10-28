#!/usr/bin/env python3
"""Exercise docs-aware gating, one-build fan-out, and isolated native coverage."""
import itertools
import os
from pathlib import Path
import re
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


def main():
    text = WORKFLOW.read_text()
    sections = jobs(text)
    gate = sections['checks']
    assert re.search(r'^    if: \$\{\{ always\(\) \}\}$', gate, re.MULTILINE)
    assert dependencies(gate) == set(sections) - {'checks', 'prune-caches', 'known-limitations'}
    bindings = dict(re.findall(r'^          ([A-Z_]+): \$\{\{ needs\.([a-z]+)\.result \}\}$', gate, re.MULTILINE))
    assert set(bindings.values()) == dependencies(gate)
    assert 'continue-on-error:' not in ''.join(value for name, value in sections.items() if name != 'known-limitations')
    advisory = sections['known-limitations']
    assert dependencies(advisory) == {'changes', 'build'}
    assert 'continue-on-error: true' in advisory
    assert '--suite known-limitations' in advisory
    assert '--suite required' in sections['native']
    assert '--count 1' in advisory
    assert 'scripts/run-native-tests.py' in advisory
    assert 'if: ${{ always() }}' in advisory
    assert 'actions/upload-artifact@v6' in advisory
    assert 'GITHUB_STEP_SUMMARY' in advisory
    assert "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT: '90'" in sections['native']
    assert 'APP_REQUIRED: ${{ needs.changes.outputs.app_required }}' in gate
    script = block(gate)
    trials = 0
    for app in ('true', 'false'):
        for states in itertools.product(('success', 'failure', 'cancelled', 'skipped'), repeat=len(bindings)):
            results = dict(zip(bindings.values(), states))
            wanted = results['changes'] == 'success' and all(
                value == ('success' if app == 'true' else 'skipped')
                for name, value in results.items() if name != 'changes')
            env = {**os.environ, **dict(zip(bindings, states)), 'APP_REQUIRED': app}
            actual = subprocess.run(['bash', '-c', script], env=env, capture_output=True)
            assert (actual.returncode == 0) == wanted, (app, results, actual.stdout)
            trials += 1
    for key in [*bindings, 'APP_REQUIRED']:
        for value in ('', 'unknown', 'success\nsuccess', '$(exit 0)'):
            env = {**os.environ, **dict.fromkeys(bindings, 'success'), 'APP_REQUIRED': 'true', key: value}
            assert subprocess.run(['bash', '-c', script], env=env, capture_output=True).returncode != 0
            trials += 1
        env = {**os.environ, **dict.fromkeys(bindings, 'success'), 'APP_REQUIRED': 'true'}
        env.pop(key)
        assert subprocess.run(['bash', '-c', script], env=env, capture_output=True).returncode != 0
        trials += 1

    assert 'runs-on: ubuntu-latest' in sections['changes']
    assert 'fetch-depth: 0' in sections['changes']
    assert 'scripts/ci-change-scope.py' in sections['changes']
    for name in ('source', 'build', 'native', 'packaging'):
        section = sections[name]
        assert "if: needs.changes.outputs.app_required == 'true'" in section
        assert dependencies(section) == ({'changes', 'build'} if name in ('native', 'packaging') else {'changes'})
    build, native, packaging = (sections[name] for name in ('build', 'native', 'packaging'))
    assert 'swift build --build-system native -c debug --build-tests' in build
    assert 'run: ./make-app.sh debug --skip-app-build\n' in build
    assert 'uses: actions/cache/restore@v6' in build and 'uses: actions/cache/save@v6' in build
    assert "github.event_name == 'push' && github.ref == 'refs/heads/main'" in build
    assert 'scripts/ci-build-artifact.py pack' in build
    assert 'name: debug-runtime' in build and 'compression-level: 0' in build
    for section in (native, packaging):
        assert 'uses: actions/download-artifact@v5' in section
        assert 'name: debug-runtime' in section
        assert 'scripts/ci-build-artifact.py restore' in section
        assert 'swift build' not in section
        assert 'actions/cache/' not in section
        assert './make-app.sh' not in section
    assert 'secrets.' not in build + native + packaging
    assert 'fail-fast: false' in native
    assert 'shard: [1, 2, 3, 4]' in native
    assert '--index "$NATIVE_SHARD" --count 4' in native
    assert 'NATIVE_SHARD: ${{ matrix.shard }}' in native
    assert 'swift test --build-system native list --skip-build' in native
    assert 'scripts/native-test-shards.py plan' in native
    assert 'scripts/run-native-tests.py --build-system native --skip-build --jobs 1' in native
    assert 'scripts/native-test-shards.py verify' in native
    assert 'name: native-loop-logs-${{ matrix.shard }}' in native
    assert "VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT: '1200'" in native
    assert "VANE_APPKIT_LOOP_SMOKE: '1'" in native
    assert 'Native suite primary status=0; cleanup status=0' in native
    assert native.index('Owned AppKit loop preflight') < native.index('Native regression tests')
    assert 'Preserve native loop failure evidence\n        if: ${{ always() }}' in native
    for command in ('node docs/tests/galaxy.test.cjs', 'python3 scripts/test-ci-source-state.py',
                    'python3 scripts/test-native-fixture-runner.py', './.build/debug/vane selfcheck --pure',
                    'scripts/check-webkit-startup.sh', 'scripts/check-app-icons.sh'):
        assert text.count('run: ' + command) == 1, command + ' must run once'
    for fixture in ('test-checks-workflow.py', 'test-native-test-shards.py', 'test-ci-build-artifact.py', 'test-ci-change-scope.py'):
        assert fixture in sections['source']
    assert dependencies(sections['prune-caches']) == {'changes', 'checks'}
    assert "needs.changes.outputs.app_required == 'true'" in sections['prune-caches']
    print(f'PASS: {trials} gate cases; docs skips and one-build fan-out preserve failures and native coverage')


if __name__ == '__main__':
    main()
