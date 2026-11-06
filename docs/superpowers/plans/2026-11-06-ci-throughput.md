# CI throughput improvements

The user requests direct implementation of maintainable CI/CD speedups with every
essential check preserved. Work from the existing single-build/four-desktop design.

## Constraints

Keep source fixtures, complete discovered native coverage, class isolation, lifecycle
preflights, cleanup, failure artifacts, packaging checks, strict aggregate gate and
main-only cache writes. Release products contain an OAuth secret and remain uncached;
signing, two notarizations and delayed publication remain mandatory. Do not add macOS runners.

## Task 1: Restore all build inputs safely

- Extend `scripts/test-ci-source-state.py` with unchanged/changed C, Objective-C,
  headers, module maps and resource inputs; additions and removals stay visible.
- Run the fixture first: the current Swift-only snapshot must fail the new assertions.
- Extend `inputs(root)` in `scripts/ci-source-state.py` to regular files under Sources
  and Tests as well as package manifests. Keep content matching and corrupt-cache fallback.
- Version the debug cache key, include all source/test inputs and cache policy, and
  keep the compatible old prefix as a migration fallback. Prune obsolete debug caches.
- Extend the workflow fixture to protect complete keys, fallback, and main-only writes.
- Validate: `python3 scripts/test-ci-source-state.py` and
  `python3 scripts/test-checks-workflow.py` must pass. Repeat the tiny Swift/C package
  checkout simulation to verify no compile after a complete timestamp restore.

## Task 2: Rebalance existing native desktops

- Derive advisory class weights from completed required-suite logs and manifests in
  three successful recent runs (42194913597, 42110187620, 42090704406).
- Use median class totals; include every class (including small and skipped classes),
  recording provenance. Discovery and the existing planner still define coverage.
- Replay the existing planner against saved inventories and actual durations, comparing
  old/new maximum shard totals. Run `python3 scripts/test-native-test-shards.py`.

## Task 3: Verify and document

- Add a CI analysis covering triggers, dependencies, caches, measured step timings,
  chosen improvements, rejected complexity, and measured versus estimated benefits.
- Update developer cache documentation. Validate source/workflow/shard fixtures,
  release fixtures, actionlint when available, and `git diff --check`.
- Obtain independent review of the final diff, fix findings, and run required hosted
  CI via a PR. Observe cold migration versus subsequent warm-cache behavior separately.
- Squash-merge only after required checks and review pass on the latest base and all
  main runs finish. Preserve unrelated work; clean up the task checkout afterward.

## Review focus

Content changes, added/removed native inputs, tests-only cache revisions, cache
migration/pruning, release-secret separation, and complete native inventory coverage.

## Follow-up target: 2× faster where possible

The user asked for a 2× target after the initial implementation. Prioritize the
warm-cache path without promising a universal cold-build or queue-time speedup.

- Run mandatory website/routing fixtures in a separate Ubuntu job alongside scope
  detection; require its success for both fast/full paths. Preserve exhaustive gate
  cases with a batched Bash harness (fresh subshell and errexit per case).
- Disable IDE index-store generation in the CI debug build; retain debug symbols,
  testability, complete test discovery and runtime validation. Include workflow
  build policy in the immutable cache key.
- Reuse the two CI debug helper executables only when source contents, arguments,
  packaging policy and trusted toolchain match. Fresh release/local builds continue
  compiling. Test source/toolchain/policy changes, missing outputs and missing key.
- Revalidate and obtain independent review of the expanded final diff. Compare
  hosted cold migration and warm builds separately; measure rather than claim 2×.
