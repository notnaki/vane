# CI performance analysis — 6 November 2026

This change builds on [PR #589](https://github.com/notnaki/vane/pull/589), including
its website/routing fast path. Every existing validation still runs for applicable
changes. Native tests retain four isolated desktops and sequential execution.

## Workflow operation

`checks.yml` runs on pull requests and pushes to `main`. Its PR concurrency group
cancels superseded PR runs; every main run has a unique group so a later push cannot
cancel active or pending main validation. The workflow token has read-only contents
access; scope detection also receives read-only Actions/PR access for native reuse
verification. Only the post-validation cache-pruning job receives cache deletion permission.

1. **Change scope and diff checks** (Ubuntu) fetches history, runs `git diff --check`,
   and conservatively determines `app_required`. PRs compare the base with the tested
   merge revision; pushes compare the previous and current revisions. Missing history,
   empty diffs, app/mixed/unknown paths, and native workflow edits select full checks.
   The separate routing job validates the fast path as well.
2. **Website and routing fixtures** (Ubuntu) runs independently of scope detection.
   It retains all website configurations and routing/aggregate-gate assertions.
   App compilation can start when scope detection finishes instead of waiting for
   these fixtures. Their success is mandatory in the final gate for both paths.
3. **Source fixtures** (macOS 26) and **Shared debug build** (macOS 26) depend on scope
   and run independently for app changes. Source fixtures exercise release policy,
   resources, cache safety, native shard coverage, runner safety and related scripts.
4. **Shared debug build** fingerprints Swift, Xcode and SDK, restores `.build`, restores
   content-matching input timestamps, and always runs native SwiftPM debug compilation
   with `--build-tests --disable-index-store`. IDE indexing is unnecessary in CI;
   debug symbols and testability remain enabled. It bundles without invoking a second
   SwiftPM build engine. The two standalone XPC helpers compile on a cache miss and
   reuse only content/arguments/policy/toolchain-matching CI debug products. A gzip level-1 runtime archive
   contains executable/test/resource products, provenance and the native lease holder.
   Artifact upload uses compression level 0 to avoid recompressing that archive.
5. **Native regressions (1–4)** and **Packaging and integrations** start after the
   shared build. Consumers validate revision, toolchain and checkout path before
   extracting the runtime; none rebuild or restore compiler caches. Each native runner
   discovers the full test inventory, assigns whole classes using advisory weights,
   runs its owned AppKit-loop preflight, then tests with `--skip-build --jobs 1`.
   Fatal signals, primary/cleanup failure and missing completions fail the run.
   Every shard uploads its manifests and logs even on failure. Packaging separately
   validates selfchecks, cold WebKit startup, icons, CLI import, cloud transport,
   DMG lifecycle and updater rollback/transport/relaunch/installer behavior.
6. **checks** (Ubuntu) always evaluates all required results. Intentional app-job
   skips pass only when scope selected the fast path or native reuse was verified;
   failures and unexpected skips
   fail closed. Strict current-base branch protection, including administrators,
   remains required. After successful main checks, **prune-caches** retains two
   recent debug caches across cache-key generations.

Only main builds save compiler caches. PRs can restore matching main caches but
cannot populate a per-revision cache. The exact v3 key includes OS, architecture,
toolchain, package manifests, every file under Sources/Tests, and timestamp/bundling/workflow
policy. Prefix fallback permits incremental reuse across source revisions with the
same package/toolchain. A v2 fallback avoids throwing away the existing cache during
migration. Files are restored only when their current content hash matches the
snapshot; new, changed and deleted inputs remain visible to SwiftPM. Directory
mtimes are left alone so resource/header membership changes remain visible.

`release.yml` runs on `v*` tag pushes, manual stable/nightly dispatches, and a daily
02:23 UTC schedule. A serialized release queue preserves pending release requests.
The read-only Ubuntu preparation job checks exact-main CI eligibility and whether
that nightly revision was already published; unchanged/unready nightlies stop here.
A qualifying macOS 26 job checks out the exact revision with full history, requires
all signing/notarization credentials, selects an idempotent version/tag, imports its
signing keychain, and optionally embeds the OAuth secret. It builds the optimized
app, smoke-tests it and checks the pinned signing team, notarizes/staples/validates
the app, then creates ZIP and DMG from that stapled app. The DMG is independently
signed/notarized/stapled/validated. Credentials are cleaned up on success or failure.
Dispatch-created tags push only after packaging succeeds; publication handles retries
and keeps nightlies away from the stable latest release. Release build products are
never cached because they can contain the OAuth secret.

GitHub also runs its managed `pages-build-deployment` workflow after main pushes;
that hosting pipeline is outside these two checked-in workflows.

## Measured baseline

Job/step durations below come from successful runs
[42194913597](https://github.com/notnaki/vane/actions/runs/42194913597),
[42110187620](https://github.com/notnaki/vane/actions/runs/42110187620),
[42090704406](https://github.com/notnaki/vane/actions/runs/42090704406),
[42076639720](https://github.com/notnaki/vane/actions/runs/42076639720), and
[42064851539](https://github.com/notnaki/vane/actions/runs/42064851539).
Queue time and rerun delays are separate from execution: some runs had tens of
minutes between runnable jobs. Adding more macOS jobs would not reliably help.

| Work | Observed duration | Implication |
| --- | ---: | --- |
| Shared debug build job | 405–500 s | On the critical path before all runtime tests |
| Swift app/test compilation | 320–412 s | Dominant even after a successful cache restore |
| Debug cache restore | 9–14 s | Approximately 283 MiB transferred in the sampled log |
| Bundle assembly/helpers | 31–45 s | Smaller than compilation; helpers intentionally still compile |
| Runtime archive packaging | 12–20 s | Already compressed once, runtime products only |
| Slowest native job | 329–443 s | Second critical-path stage |
| Source fixtures | 67–124 s | Parallel with build; usually not critical |
| Packaging/integrations | 124–174 s | Parallel with native; usually not critical |

The [14m18s release run](https://github.com/notnaki/vane/actions/runs/42104662114)
spent 714 s building, 14 s smoke-testing, 28 s notarizing/stapling the app and 55 s
packaging/notarizing the DMG. Preparation took 13 s. Recent unchanged nightly
preparations completed in roughly 15–20 s without scheduling a release build.

## Changes and expected impact

**Complete timestamp restoration.** Previously only Swift/package files were
recorded. Hosted logs show all C/Objective-C support targets compiling despite a
cache hit and 631 unchanged Swift/package timestamps restored. A small Swift/C
package reproduced dependent Swift recompilation when header timestamps were left
fresh. The updated fixture covers C, Objective-C, headers, module maps and resources,
including changed/new/deleted inputs. A real local SwiftPM probe confirmed that a
complete restore performs no compilation, a changed C implementation rebuilds and
relinks, and a changed bridge header recompiles the Swift consumer. This removes a
cause of broad cache invalidation and can save minutes on subsequent warm builds;
source/dependency/toolchain changes can still require substantial compilation.

**Complete immutable cache keys.** Previously tests-only and native-input changes
could hit an exact source-only key, preventing an updated cache from being saved.
The v3 key includes those inputs and the timestamp policy. The first migration run
may use v2 and rebuild; it cannot recover native timestamps the old snapshot never
recorded. Main must save a complete v3 snapshot before normal PR/main runs receive
the full benefit. Main-only saves and release-secret isolation remain unchanged.

**Refresh advisory shard weights.** The old table covered 96 classes; the new table
covers 344 observed classes, using median per-class totals from three successful
required suites. For each run, only methods selected in its shard manifests enter
the totals. The first primary-phase completion per selected method supplies the
parent elapsed duration, including isolated child-host overhead. Later buffered
child duplicates, separate preflights and cleanup executions are excluded. Skipped methods
retain their reported duration. Weights affect placement only; discovery, exact-once
partitioning and completion verification still define coverage.

Replaying the existing greedy planner against the recorded inventories and method
durations gives the following counterfactual maximum test time per shard:

| Successful source run | Old weights | New weights | Reduction |
| --- | ---: | ---: | ---: |
| 42194913597 | 341.7 s | 270.5 s | 20.8% |
| 42110187620 | 348.0 s | 277.7 s | 20.2% |
| 42090704406 | 272.9 s | 264.2 s | 3.2% |

These are replay estimates, not measured new CI runtimes. They exclude startup,
preflight, cleanup, queue delays and effects of changed test order. Updated weights
suggest roughly one minute off the native critical path in two samples, with much
less benefit in the third. The full required hosted suite validates the new grouping.

**Remove duplicate source fixtures after #589.** Website scenes, routing and the
aggregate-gate fixture now execute once on Linux alongside scope detection and app jobs. Their former
macOS copies consumed roughly 45–80 s per app run, mostly website and gate fixtures.
This saves runner work; because source fixtures already ran alongside the longer
build, it does not directly remove 45–80 s from the critical path. No tests or
assertions were removed.

Using these same inventories and corrected timings, median longest-shard test time
is 1,030.7 s with one runner, 534.3 s with two, and 270.5 s with four. Fewer runners
reduce setup work but serialize far more tests. Keep four for end-to-end latency;
these estimates exclude setup and queueing, so severe capacity constraints should
be assessed separately.

## Additional work toward the requested 2× target

The first PR run measured 49 s in universal fixtures after a 9 s checkout, before
any app compilation could start. These now run in a parallel Ubuntu job. The new
routing result is required on every path; the expanded gate fixture evaluates
8,227 combinations, including missing/invalid values. It batches real Bash execution
with a fresh subshell per case, retaining errexit and nounset; all previous cases
remain. This avoids launching thousands of new Bash interpreters. No extra macOS
runner or test desktop was added.

The CI debug compiler now disables IDE indexing. A real SwiftPM/XCTest probe
built without any index store, then discovered and ran its tests with the same
skip-build commands used by the consumers. Debug symbols, testability, compiler
checks and runtime assertions remain enabled. A workflow-policy hash in the cache
key ensures compiler-policy changes get a fresh immutable snapshot.

CI debug assembly can also reuse the two standalone helpers. Their cache stamp
includes the trusted Swift/Xcode/SDK fingerprint, all compiler arguments, input
contents and the packaging script itself. Missing/non-executable products or
missing/mismatched stamps rebuild. Source changes invalidate the affected helper;
toolchain or policy changes invalidate both. Ordinary local and release packaging
always compile. The bundled copies still receive fresh signing and validation. A real local compile
of both production helper source sets took 11.31 s; a matching repeated invocation
took 0.36 s. These local timings establish reuse, not a hosted end-to-end speedup.

A 2× target means roughly 7–8 minutes instead of the observed 14–16 minute full
runs without major queue delays. It is plausible for a warm, small-change build
if shared-build work drops below about 100 s and the slowest native job stays
near 300 s. This is a performance budget, not a measured result. Cold/full-source
recompilation, platform changes and hosted queue delays can prevent that target.
Required hosted CI and a subsequent warm v3 run must establish the actual result.

## Boundaries and follow-up measurement

Keep the existing single-build artifact fan-out, four native runners, failure
artifacts and separate packaging desktop. Increasing shard count or using
same-desktop parallel tests risks queueing and shared AppKit/WebKit state. Full
history supports safe scope detection and release version/build numbering. Runtime
archive compression is already low-cost. Moving platform-sensitive source fixtures
to Linux could drop Darwin-only assertions. Those changes are not justified by the
critical-path data. Release build caching is excluded by the secret boundary, and
its notarizations must remain sequential around the stapled app.

After merging, compare build steps on a **warm v3** cache with unchanged bridge/header
content against the baseline above. Inspect actual compiled targets and cache keys,
then compare the maximum of all four native jobs. Track queue delay separately.
A source-heavy PR or cold/toolchain-mismatched build is not a valid warm-cache
comparison. Refresh the advisory table periodically using the listed runs' downloadable
`native-loop-logs-*` artifacts: take the first completion of each selected method before the primary/cleanup
boundary, sum by class per run, take the median across successful runs, and retain provenance in the JSON. Do not derive
weights from failed or incomplete suites.

## Identical-tree native reuse — 7 November 2026

The serial cost matters when landing many PRs: a successful PR suite is followed by
another main suite before the next merge. For example,
[PR run 42324736011](https://github.com/notnaki/vane/actions/runs/42324736011)
took about 12 minutes, then [main run 42325877540](https://github.com/notnaki/vane/actions/runs/42325877540)
took about 11 minutes. These are observed elapsed times including queue/setup work,
not a prediction for every change.

PRs still execute all selected checks. Main can reuse only the four native shards
from a fully successful PR run when `scripts/ci-native-reuse.py` verifies:

- The push contains one squash commit whose parent is exactly the previous main.
- Exactly one associated merged PR targets this repository's main, has that squash
  SHA, and has a head in the same repository. Forks fall back to normal validation.
- Across all open/closed PRs, that source branch must have been used by exactly
  this PR. Its complete timeline must contain no manual or automatic base change,
  and the source run must have started after the PR was created. This binds the
  run to the intended PR and target even when GitHub drops closed PRs from a run's
  `pull_requests` metadata. Reused branches and retargeted PRs run native tests again.
- The entire PR head tree equals the main tree, including tests, scripts, resources
  and workflow policy. The previous main is also an ancestor of that PR head, so
  the tested PR integration had the same tree; stale integrations do not qualify.
- The latest matching `pull_request` run of this workflow, including its latest
  attempt, completed successfully before the merge. All four native shards, build,
  packaging, source, routing, diff checks and aggregate must each occur once and
  pass in that attempt. All API pages are examined, and current run metadata is
  rechecked after the job evidence to reject a concurrent rerun.

Missing history, changed trees/bases, multi-commit pushes, unavailable APIs, malformed
metadata, missing jobs, failed/skipped/cancelled jobs, newer non-passing attempts,
and other events all retain the full native suite. The verifier downloads no
artifacts and executes no code from earlier runs. Its decision and source-run link
appear in the Actions summary. Read-only API calls have per-command timeouts.

Main continues its fresh build, source/routing fixtures, packaging and integration
checks. These cover commit-dependent bundle metadata and keep main's compiler cache
warm for following PRs. The aggregate permits a native skip only for a verified
app-required push to main; other selected jobs still must succeed. Main-only cache
saves/pruning, release eligibility, strict branch protection and administrator
enforcement remain in force.

This removes four duplicate macOS jobs per eligible merge and their test stage
from main's critical path. It does not remove the PR suite or the subsequent main
build/packaging wait. Actual savings depend on compilation, packaging and runner
availability; measure the first eligible main run before claiming an end-to-end
speedup. GitHub's merge queue is not available for this personally owned repository
([availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)).
