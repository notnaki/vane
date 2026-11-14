# Required checks reliability investigation — 15 November 2026

Base: `f26710cd` (`origin/main`). Collection is a fixed 150-run snapshot, not a
claim about all historical runs or the excluded work in PR #677.

```sh
gh run list -w checks -L 150 --json databaseId,conclusion,headBranch,event,createdAt
gh run view <failed-or-cancelled-id> --log-failed
# Also inspect complete logs for cancelled jobs, which --log-failed omits:
gh run view <cancelled-id> --log
```

The unmodified listing is [runs.json](runs.json). Exclude any branch containing
`library`, `profile`, `motion`, `cadence`, `land-final`, or `sidebar` (case insensitive).
44 runs are excluded. Of the remaining 106 runs: **70 success, 16 failure,
16 cancelled, 4 with no conclusion**. The included PR-only population is
77 runs: 42 success, 15 failure, 16 cancelled, 4 with no conclusion. One of the
29 included main pushes failed. Empty conclusions are not counted as successes
or failures.

## Causes

Counts are **runs containing the cause**, not assertion lines. Causes can overlap;
for example, 43195843012 has both shadow discovery and snapshot failures.
The aggregate `checks` failure and fail-fast sibling cancellations are consequences,
not additional root causes. All 16 failure-conclusion runs reached native tests.

| Observed cause | Failed runs | Cancelled runs with this failure before cancellation |
| --- | ---: | ---: |
| Snapshot pointer/probe or native occlusion admission timeout | 6 | 0 |
| Password shadow-document/field-discovery readiness timeout | 5 | 0 |
| Native-message fixture `incompleteHeartbeat` | 1 | 0 |
| Disabled native-row transaction assertion | 1 | 0 |
| Empty-pinned fixture activation-policy admission | 1 | 0 |
| Folder artwork interior/stroke geometry assertion | 2 | 0 |
| Retired preview navigation/redirect deadline | 1 | 0 |
| Hosted folder tooltip readiness | 1 | 0 |
| Painted viewport edge during corner resize | 1 | 0 |
| Offscreen edited-row focus/commit readiness | 0 | 1 |
| Swipe release frame sample count | 0 | 1 |
| Autofill idle selector count | 0 | 1 |
| Rejected updater redirect was fetched | 0 | 1 |
| Runner outage before test execution | 0 | 0 |
| Workflow/job timeout or primary watchdog termination | 0 | 0 |
| Captured fatal Swift signal | 0 | 0 |

All 16 cancelled runs were interrupted, not VM timeout/outage failures. Seven have
a later same-branch run created before their completion, consistent with the
workflow's supersession rule. For nine, the available logs/API do not distinguish
manual cancellation from another cancellation source; do not label those as
confirmed concurrency cancellations. Four cancelled runs had already exposed
concrete failures, listed above. Expected timeout/cleanup diagnostic strings from
`test-native-fixture-runner.py`'s negative fixtures are not real suite timeouts.

## What actually failed on main

[43525420028](https://github.com/notnaki/vane/actions/runs/43525420028), attempt 1,
head `de19eb16063a59be0182461aaa05624f33532185`, failed in shard 4's **Native
regression tests**, not its preflight. The preflight test passed and its wrapper
reported `primary status=0; cleanup status=0`. The primary shard later reported
`primary status=1; cleanup status=0` with:

- `SidebarSnapshotReadinessTests/testSnapshotRecoversAnOccludedWindowThatStillOwnsKeyboardFocus`
  timed out in `SidebarSnapshot.swift`.
- Last admission: `running=true active=true key=true owner=true visible=true
  occlusion=8192 attached=true`; native `.visible` was absent.
- No line starts with `*** Signal <number>: Backtracing`. The phrase “Swift runtime
  captured a fatal signal during tests” occurs only in the shell script Actions
  echoed before executing it. That is not a crash report.

The fixture moved its window offscreen, but snapshot recovery could re-present it
before the observer saw native occlusion. PR [#680](https://github.com/notnaki/vane/pull/680)
already repaired that race with an observable preparation gate and repaired the
native-reuse job-name mismatch that caused an unnecessary main native rerun.
The gate preserves the actual occlusion/recovery assertions and ten-second bound.
The earlier pointer-probe failures were addressed by resolving the attached probe
in its exact current host in #679. These fixes are already in this branch's base.

Other historical repairs are in #654 (idle selectors, updater redirect trust and
edited-row admission), #661 (folder artwork), #665/#667 (policy and WebKit/native
presentation readiness), #647 (disabled native-row transaction), #658 (resize),
and #679 (preview fixture). This change does not re-edit those feature paths.
Security-related shadow discovery failures and excluded motion work remain outside
this task's edit scope; historical repairs do not establish a universal absence of
future failures.

## Changes and justification

- Run the **same fresh-process owned-loop smoke test once**, in the required
  packaging job, instead of once before every native shard. Every native fixture
  still admits its own loop/presentation. Keep the 90-second primary process bound,
  four-minute step bound, native 12-second loop watchdogs, and all smoke assertions.
  A packaging failure still fails the unchanged required aggregate named `checks`.
- Remove duplicate shell greps for test pass text, heartbeat print text, wrapper
  cleanup text, and Swift signals. Extend the existing completion verifier with an
  exact `--test` selection for the smoke process. It requires that test to **pass**
  (a skip fails), checks primary/cleanup success, and rejects fatal signals even
  after a zero process exit. Native shards continue to verify their full inventory.
  Keep failure artifacts for the smoke and every shard.
- Delete **no XCTest tests** and change **no product source**. No retries,
  time-budget increases, advisory exemptions, reduced required coverage, or
  changes to concurrency/branch protection are introduced.

Successful baseline [43530171696](https://github.com/notnaki/vane/actions/runs/43530171696)
spent 16, 21, 19, and 13 seconds in the four repeated preflights: 69 runner-seconds.
One preflight at that observed range costs 13–21 seconds, removing about 48–56
runner-seconds and 13–21 seconds before each native shard. This is an estimate from
step timestamps, not a measured guarantee of total workflow latency. Build cache,
runner queue time, native test load and packaging can still determine the critical
path.

## Validation

- Verifier fixtures: 12 tests, including passing/missing/failed/skipped smoke,
  failed cleanup, and fatal signals before/after an otherwise successful result.
  Recorded the missing-API and skipped-probe failures before implementing them.
- Workflow gate: all 12,333 full/cheap/reuse/failure scenarios pass.
- Native reuse: 18 fixtures; change scope: 23 fixtures; runner ownership/cleanup:
  38 fixtures pass. Negative-case diagnostic output is expected.
- Local macOS 27 / Swift 6.4 debug build with native tests succeeded (235.28s;
  existing compiler warnings remain). Three predetermined fresh-process smoke
  repetitions passed, including post-exit retirement and the shared verifier:
  11.37s, 10.09s and 10.38s. Each ran the unchanged two loop cycles and delayed
  heartbeat regression. No task-owned test host remains running.
- `actionlint .github/workflows/checks.yml` and `git diff --check` pass.
- Hosted macOS 26 PR CI results are recorded in the PR body; local macOS 27 is
  focused preflight evidence, not a substitute for that runner environment.
- At most three CI rounds on this PR; retain every result and never rerun an
  unchanged assertion failure. No Vane app bundle was launched for investigation.

## Failed/cancelled run ledger

Each row links the actual run; job failure means the native regression step unless
explicitly marked packaging. See the exact listing for branch, event and timestamp.

| Run | Conclusion | Failed test(s) or step | Same-branch successor before completion |
| --- | --- | --- | --- |
| [43525420028](https://github.com/notnaki/vane/actions/runs/43525420028) | failure | `SidebarSnapshotReadinessTests/testSnapshotRecoversAnOccludedWindowThatStillOwnsKeyboardFocus` | Not established |
| [43517916304](https://github.com/notnaki/vane/actions/runs/43517916304) | failure | `SidebarSnapshotReadinessTests/testPointerIntrusionDiscardsThePreviousInteractivePresentation` | Not established |
| [43514239404](https://github.com/notnaki/vane/actions/runs/43514239404) | failure | `ExtensionNativeMessagingErrorTests/testReviewedSequentialRetriesYieldToTheExtensionPageTimer`; `SidebarSnapshotReadinessTests/testPointerIntrusionDiscardsThePreviousInteractivePresentation` | Not established |
| [43512037256](https://github.com/notnaki/vane/actions/runs/43512037256) | cancelled | Interrupted; no prior failed test/step recorded | 43514239404 |
| [43264140732](https://github.com/notnaki/vane/actions/runs/43264140732) | failure | `NativeSidebarMotionTests/testDisabledTransactionMovesReorderedNativeRowImmediately` | Not established |
| [43231603949](https://github.com/notnaki/vane/actions/runs/43231603949) | cancelled | Interrupted; no prior failed test/step recorded | Not established |
| [43227390633](https://github.com/notnaki/vane/actions/runs/43227390633) | failure | `PasswordShadowAutofillTests/testLateShadowDiscoveryRecoversAWithdrawnPresentation` | Not established |
| [43210954780](https://github.com/notnaki/vane/actions/runs/43210954780) | failure | `PasswordShadowAutofillTests/testLateShadowDiscoveryRecoversAWithdrawnPresentation` | Not established |
| [43206215725](https://github.com/notnaki/vane/actions/runs/43206215725) | failure | `PasswordShadowAutofillTests/testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation` | Not established |
| [43203073710](https://github.com/notnaki/vane/actions/runs/43203073710) | failure | `EmptyPinnedSectionGeometryTests/testEmptyPinnedReadinessAddsNoStackGapAndNonemptyRoundTripKeepsTodayControl` | Not established |
| [43202638419](https://github.com/notnaki/vane/actions/runs/43202638419) | cancelled | Interrupted; no prior failed test/step recorded | 43203073710 |
| [43195843012](https://github.com/notnaki/vane/actions/runs/43195843012) | failure | `PasswordShadowAutofillTests/testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation`; `SidebarSnapshotReadinessTests/testPointerIntrusionDiscardsThePreviousInteractivePresentation` | Not established |
| [43195081769](https://github.com/notnaki/vane/actions/runs/43195081769) | failure | `FolderArtworkTests/testRearStrokeDoesNotEnterFrontInteriorThroughoutTransition` | Not established |
| [43192530769](https://github.com/notnaki/vane/actions/runs/43192530769) | failure | `FolderArtworkTests/testRearStrokeDoesNotEnterFrontInteriorThroughoutTransition` | Not established |
| [43192465624](https://github.com/notnaki/vane/actions/runs/43192465624) | cancelled | Interrupted; no prior failed test/step recorded | 43192530769 |
| [43175111132](https://github.com/notnaki/vane/actions/runs/43175111132) | cancelled | Interrupted; no prior failed test/step recorded | Not established |
| [43173576399](https://github.com/notnaki/vane/actions/runs/43173576399) | failure | `SidebarSnapshotReadinessTests/testPointerIntrusionDiscardsThePreviousInteractivePresentation` | Not established |
| [43169490617](https://github.com/notnaki/vane/actions/runs/43169490617) | cancelled | Interrupted; no prior failed test/step recorded | Not established |
| [43168903681](https://github.com/notnaki/vane/actions/runs/43168903681) | cancelled | Interrupted; no prior failed test/step recorded | 43169490617 |
| [43166613756](https://github.com/notnaki/vane/actions/runs/43166613756) | failure | `SidebarSnapshotReadinessTests/testPointerIntrusionDiscardsThePreviousInteractivePresentation` | Not established |
| [43090992621](https://github.com/notnaki/vane/actions/runs/43090992621) | cancelled | `RetainedRowVirtualizationTests/testCollapsingOffscreenEditedDescendantsCommitsDraftAndClearsFocus` | Not established |
| [43086180966](https://github.com/notnaki/vane/actions/runs/43086180966) | cancelled | Interrupted; no prior failed test/step recorded | 43087475285 |
| [43080747872](https://github.com/notnaki/vane/actions/runs/43080747872) | cancelled | Interrupted; no prior failed test/step recorded | Not established |
| [43080484013](https://github.com/notnaki/vane/actions/runs/43080484013) | cancelled | Interrupted; no prior failed test/step recorded | Not established |
| [43076130072](https://github.com/notnaki/vane/actions/runs/43076130072) | cancelled | `Packaging: updater rejected redirect fetched` | Not established |
| [43075333170](https://github.com/notnaki/vane/actions/runs/43075333170) | cancelled | Interrupted; no prior failed test/step recorded | 43076130072 |
| [43072799514](https://github.com/notnaki/vane/actions/runs/43072799514) | cancelled | `SpaceCreationSwipeRenderingTests/testPacedRecordedPullOpensCreationAfterSwipingAcrossThreeProfiles` | Not established |
| [43068617044](https://github.com/notnaki/vane/actions/runs/43068617044) | cancelled | `Feel08PageToolsTests/testAutofillIdleDiscoveryAvoidsDocumentFrameSelectors` | Not established |
| [43016205658](https://github.com/notnaki/vane/actions/runs/43016205658) | failure | `PreviewLoadingPerformanceTests/testRetiredBlankNavigationAndFrameCannotMutateNewPreview` | Not established |
| [43009289019](https://github.com/notnaki/vane/actions/runs/43009289019) | cancelled | Interrupted; no prior failed test/step recorded | 43010172904 |
| [43008349348](https://github.com/notnaki/vane/actions/runs/43008349348) | failure | `TabTooltipTests/testHostedFolderTooltipStaysBesideItsRowInsteadOfTheAncestorClip`; `WindowResizeLayoutTests/testCornerResizeKeepsTheShrinkingAxisPaintedWhileTheOtherAxisGrows` | Not established |
| [43003951584](https://github.com/notnaki/vane/actions/runs/43003951584) | failure | `PasswordShadowAutofillTests/testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation` | Not established |
