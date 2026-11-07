# Reuse native validation after an identical squash merge

**Goal:** Reduce the serial PR → merge → main wait without weakening strict checks.

**Design:** PRs always run the complete selected suite. A single-commit push to
main may reuse native results from the merged, same-repository PR when its head
contains the previous main commit, its entire tree equals the pushed tree, and
the latest checks workflow run completed successfully before the merge with every
required job present and successful. Any missing, invalid or unavailable evidence
falls back to running native tests. Main still builds, packages and exercises
integrations, runs source/routing fixtures, and saves its normal compiler cache.
No artifacts or code from another run are downloaded or executed.
Source-run identity additionally requires exactly one PR ever using that branch,
no base-change events in its complete timeline, and source-run creation after PR
creation. Reused/retargeted branches conservatively run native tests again.

**Files:** `scripts/ci-native-reuse.py`, `scripts/test-ci-native-reuse.py`,
`.github/workflows/checks.yml`, `scripts/test-checks-workflow.py`,
`docs/CI-PERFORMANCE.md`.

## Task 1: Evidence and fallback

- [x] Write regression tests for identical trees, changed base/tree, forks,
  unrelated PR/workflow/event, partial/failed/skipped/cancelled/pending jobs,
  newer failed attempts, pagination, API errors, and non-main/non-push invocations.
- [x] Observe missing reuse implementation fail; implement a read-only GitHub API
  verifier with bounded calls and false-by-default output.
- [x] Exercise the verifier against completed historical runs as a read-only probe.

## Task 2: Workflow integration

- [x] Extend the real Bash aggregate-gate truth table before changing the gate.
  Reused native skips are legal only for app-required pushes to main; other job
  failures, unknown outputs, and PR skips must still fail.
- [x] Run evidence verification alongside scope detection, before scheduling jobs;
  gate only native fan-out on the verified reuse output. Retain main compilation,
  packaging/integrations, source fixtures, routing, cache saves, and cache pruning.
- [x] Keep superseded-PR cancellation but preserve each main run in its own group.
- [x] Document eligibility, fallback, retained checks, and measurement limits.

## Task 3: Validate, review, and land

- [x] Run the evidence, workflow, scope, cache/artifact, shard, and release fixtures;
  actionlint and `git diff --check`. Obtain independent review of the final diff.
- [ ] Push/open the PR, satisfy hosted checks on the latest main, squash-merge,
  and verify the actual main decision. Preserve unrelated work and clean up the
  task worktree after the result is safely preserved.

## Review focus

Latest attempt rather than an older passing attempt; complete job pagination;
exact tree and current-base proof; API errors never grant reuse; intentional
native skips never hide build, packaging, source or routing failures.

Independent review found an ambiguous source-run/PR association when a branch
targets multiple bases. The fix uses GitHub's all-state branch PR listing and
complete base-change history (server metadata rather than a self-reported artifact).
Regression cases first reproduced wrong-PR, retargeted-PR, old-run, and later-page
omissions, then passed with the conservative identity checks.

## Hosted native failure repair

Run [42356549050, shard 1](https://github.com/notnaki/vane/actions/runs/42356549050/job/128356428255)
failed the existing Easel F6 focus assertions. The original local case passed once;
that did not resolve the hosted failure. An explicit fixture prerequisite reproduced
an unadmitted window locally: `running=false active=false policy=2 key=false`,
while the Easel page owner and first responder were correct. The Easel case had
neither the owned loop nor foreground admission used by neighboring fixtures.

Reuse the existing owned page-fixture helper for normal profiles, then admit the
mounted Easel/chrome owner before the action. Preserve the original 150ms outcome
sample and both focus-direction assertions; no product code or result deadline
changes. Predetermine three fresh-process focused runs of the entire keyboard
class plus owned-loop smoke tests, keeping each log and verifying post-exit profile
retirement, before another full hosted run. Original logs and local RED/attempt
logs are retained outside the task worktree under `/tmp/vane-pr603-*`.
