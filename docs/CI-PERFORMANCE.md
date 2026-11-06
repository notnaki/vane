# CI performance analysis — 6 November 2026

This change builds on [PR #589](https://github.com/notnaki/vane/pull/589), including
its website/routing fast path. Every existing validation still runs for applicable
changes. Native tests retain four isolated desktops and sequential execution.

## Workflow operation

`checks.yml` runs on pull requests and pushes to `main`. Its branch/PR concurrency
group cancels superseded runs. The workflow token has read-only contents access;
only the post-validation cache-pruning job receives cache deletion permission.

1. **Change scope and diff checks** (Ubuntu) fetches history, runs `git diff --check`,
   and conservatively determines `app_required`. PRs compare the base with the tested
   merge revision; pushes compare the previous and current revisions. Missing history,
   empty diffs, app/mixed/unknown paths, and native workflow edits select full checks.
   PR #589 adds website and routing regression fixtures here, even on the fast path.
2. **Source fixtures** (macOS 26) and **Shared debug build** (macOS 26) depend on scope
   and run independently for app changes. Source fixtures exercise release policy,
   resources, cache safety, native shard coverage, runner safety and related scripts.
3. **Shared debug build** fingerprints Swift, Xcode and SDK, restores `.build`, restores
   content-matching input timestamps, and always runs native SwiftPM debug compilation
   with `--build-tests`. It bundles without invoking a second SwiftPM build engine,
   including compiling the two standalone XPC helpers. A gzip level-1 runtime archive
   contains executable/test/resource products, provenance and the native lease holder.
   Artifact upload uses compression level 0 to avoid recompressing that archive.
4. **Native regressions (1–4)** and **Packaging and integrations** start after the
   shared build. Consumers validate revision, toolchain and checkout path before
   extracting the runtime; none rebuild or restore compiler caches. Each native runner
   discovers the full test inventory, assigns whole classes using advisory weights,
   runs its owned AppKit-loop preflight, then tests with `--skip-build --jobs 1`.
   Fatal signals, primary/cleanup failure and missing completions fail the run.
   Every shard uploads its manifests and logs even on failure. Packaging separately
   validates selfchecks, cold WebKit startup, icons, CLI import, cloud transport,
   DMG lifecycle and updater rollback/transport/relaunch/installer behavior.
5. **checks** (Ubuntu) always evaluates all required results. Intentional app-job
   skips pass only when scope selected the fast path; failures and unexpected skips
   fail closed. Strict current-base branch protection, including administrators,
   remains required. After successful main checks, **prune-caches** retains two
   recent debug caches across cache-key generations.

Only main builds save compiler caches. PRs can restore matching main caches but
cannot populate a per-revision cache. The exact v3 key includes OS, architecture,
toolchain, package manifests, every file under Sources/Tests, and timestamp/bundling
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
the totals; separate preflights and cleanup executions are excluded. Skipped methods
retain their reported duration. Weights affect placement only; discovery, exact-once
partitioning and completion verification still define coverage.

Replaying the existing greedy planner against the recorded inventories and method
durations gives the following counterfactual maximum test time per shard:

| Successful source run | Old weights | New weights | Reduction |
| --- | ---: | ---: | ---: |
| 42194913597 | 340.8 s | 273.1 s | 19.9% |
| 42110187620 | 348.0 s | 287.1 s | 17.5% |
| 42090704406 | 272.9 s | 267.7 s | 1.9% |

These are replay estimates, not measured new CI runtimes. They exclude startup,
preflight, cleanup, queue delays and effects of changed test order. Updated weights
suggest roughly one minute off the native critical path in two samples, with much
less benefit in the third. The full required hosted suite validates the new grouping.

**Remove duplicate source fixtures after #589.** Website scenes, routing and the
aggregate-gate fixture now execute once on Linux before app jobs. Their former
macOS copies consumed roughly 45–80 s per app run, mostly website and gate fixtures.
This saves runner work; because source fixtures already ran alongside the longer
build, it does not directly remove 45–80 s from the critical path. No tests or
assertions were removed.

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
`native-loop-logs-*` artifacts: sum selected methods by class per run, take the
median across successful runs, and retain provenance in the JSON. Do not derive
weights from failed or incomplete suites.
