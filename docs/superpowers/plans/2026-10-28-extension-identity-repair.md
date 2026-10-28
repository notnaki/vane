# Extension identity and Bitwarden repair

> **For agentic workers:** Implement inline using systematic debugging and TDD. Obtain independent review of each proposed shipping PR before merging.

**Goal:** Repair the remaining failures tracked by issues 484 and 513, preserving real-package and first-start identity assertions.

**Architecture:** Start from current main. Extract only demonstrated host repairs from prior diagnostic drafts. Use signed, isolated actual-Vane acceptance for Bitwarden and a source-backed initial-worker test for MV3; never count retries, extra delays, instrumentation-only passes, or an engine upgrade as a repair.

**Tech stack:** Swift, AppKit/WebKit, XCTest, signed task-owned diagnostic executables, Python process-identity/cleanup guards.

**Spec:** User request in this chat targets issues 513 and 484; PRs 519, 520 and 503 are investigation references.

## Constraints

- System WebKit and macOS 26.0+; no bundled/forked engine, extension-resource rewriting, altered security boundaries, or weaker assertions.
- Keep main's strict checks and current-base integration requirement. No issue-closing keywords until each issue's acceptance is actually satisfied.
- Preserve prior failing evidence and other tasks' worktrees/data. Track and retire every task-owned native launch.
- Vendor-signed Bitwarden 2026.10.0 is cached locally. After an initial stalled download, the user installed the exact Store 2026.10.0 copy. Apple signature/team/receipt were verified and all 185 resource files match the vendor package. Its signed Safari-app installer path still fails the original welcome deadline; successful acceptance remains pending.

## Evidence already established

- Issue 484: the Safari identity change is on main, but a reported optional runtime script error (context error 7) can race a successful background completion and cause Vane to reject activation. Prior PR520's focused classification repair was reviewed/tested but is not on main. With that candidate, the vendor popup's welcome DOM still did not reply within its original 20-second deadline.
- Issue 513: signed same-binary fresh launches and a public-only reduction have returned a bare worker UA despite correct native/registering-page/popup UA. Default-policy cleanup in PR519, observer registration and a newer WebKit did not eliminate it. Atomic fallback seeding and initial client-map identity are hypotheses, not proven failure causality. Prior source audit found no supported atomic host API.

## Task 1: Preserve runtime diagnostics without rejecting a working background

- [x] Add a literal domain/code classification regression against current main; observe the script diagnostic incorrectly remain blocking.
- [x] Add a real MV2 background that throws after registering its message listener; require a new popup to receive its nonce and require every reported diagnostic remain visible.
- [x] Separate display errors from activation-blocking errors. Only context-domain code 7 is nonblocking after successful background completion; code 6, wrong domains, unknown codes, callback errors and the original 10-second deadline remain blocking.
- [x] Run the focused live background/restore/update controls and independent review before proposing this repair for integration.

Local focused result: 34 passed, primary 0 / cleanup 0. Reviewed PR548 passed required CI and merged as `a53f181`; its actual-main CI failure is tracked below.

## Task 2: Identify and repair the remaining Bitwarden popup failure

- [x] Reuse verified vendor resources read-only; create fresh task-owned copies and record their digests/provenance.
- [ ] Exercise the actual installer, anchored popup, close/reopen and fresh-process restoration in a signed isolated app, without credentials.
- [ ] Preserve the original 20-second welcome/control/identity verdict. If it fails, identify the executing document and API/JavaScript boundary before proposing a fix; post-failure inspection cannot change the verdict.
- [ ] Add a deterministic regression for any demonstrated host defect, then run uninstrumented real-package acceptance. Exact Store provenance remains a distinct acceptance requirement.

Current result: actual anchored-popup welcome JavaScript still times out at 20 seconds after successful installation. Bounded Promise-registration tracing now identifies `background.html` and Bitwarden's `checkSafari` loop: its `sendMessageToApp("sleep")` calls the unavailable native-messaging API, immediately rejects, catches, and repeats through microtasks. Registrations at counts256,4096,65536 retain the same source stack. The signed Store bundle reproduces this; a clean observer control passes. This diagnostic does not establish popup acceptance. Post-failure and inspector diagnostics remain separate non-acceptance arms, and original failures/scoped-store retirement logs are preserved.

The Store-bundle path reproduces that same deadline failure. The complete Vane executable restored the accepted extension as enabled with the runtime diagnostic visible; its bounded UI experiment produced no passing popup acceptance verdict. Early inspector experiments missed `developerExtrasEnabled`; their connection timeouts are not evidence about the extension's cause. A corrected clean-page inspector control subsequently passed.

## Task 3: Establish a safe MV3 identity repair

- [x] Compare current upstream and pinned system source at initial origin/client-UA selection and worker installation; avoid repeating ruled-out API/casing/observer/engine experiments.
- [ ] Require a causal, controllable reproduction or host configuration violation before changing product code. Add a failing regression for the chosen boundary.
- [ ] Implement only a supported or already guarded host integration change that preserves stores, controllers, origin/runtime identity and grants. If the demonstrated repair requires an engine change, retain an explicit external blocker rather than shipping an unproven workaround.
- [ ] Validate default Safari, custom identity, Safari-after-custom and recreated workers with first-failure-stop signed acceptance on macOS 26 and local macOS 27; retain all original identity/ownership checks.

## Integration

- [ ] Independently review the current shipping diff, pass required CI against latest main, squash-merge, verify main, and clean up task-owned launches/worktree when safe.
- [ ] Update issue status only for demonstrated acceptance; keep unresolved items open and report precise remaining blockers.

## Priority follow-up: main CI run 1608

Activation repair PR548 merged as `a53f181` after exact-head review and green PR run40741107431 attempt1. Main run40745249461 then failed a native `launchTimedOut` assertion and silent DMG exit16. Preserve that original run; do not retry it to establish a repair.

- [x] Reproduce a false native timeout with controlled six-second heartbeat scheduling delay: launch was finished at entry and at observation, but the previous policy still threw `launchTimedOut`.
- [x] Separate already-finished launch admission from genuine launch waiting. Preserve the five-second unfinished-launch deadline and twelve-second lifecycle watchdog, including an explicit absolute guard when a timer callback is delayed.
- [x] Require the controlled native regression in every existing owned-loop CI preflight. Add deadline/changed-readiness/overdue-watchdog controls without a new skipped test or exclusion.
- [x] Add exact image/device ownership checks, bounded EBUSY-only detach handling, safe partial-attach cleanup, and command-stage diagnostics. The original DMG log does not identify which command returned16; treat detach as a demonstrated vulnerability rather than proven historical causality.
- [x] Local verification:68 native tests passed, zero failures, primary0/cleanup0,28 exact owned backends absent; nine packaging mock regressions and one full live packaging run passed with owned images retired and pre-existing images preserved.
- [ ] Independently review, pass latest-main required CI, squash-merge, and verify a fresh actual-main run. Both extension issues remain open.

PR549 run40751415931 attempt1 passed packaging and the originally failing native shard, but failed `SpacePreviewParityTests.testNewProfileDoesNotBorrowAnotherWindowsFavouriteSelection` with26724 differing bitmap bytes (limit10). Preserve that run without retrying unchanged code. Its exact historical image was not retained, so the specific mismatch cannot be attributed conclusively.

- [x] Demonstrate another fixture defect: holding actual native row geometry past the old20ms sleep lets the old snapshot helper capture zero rows. The repaired helper requires exact current viewport attachment and scoped committed population; another ready same-store/Space surface cannot satisfy admission. Keep the image threshold and immediate raw motion capture unchanged.
- [x] Audit all10 native static parity capture sites. Full-content captures use the production root owner/epoch; standalone sections declare fixture-owned population with unique surface/owner IDs; scroll-offset capture admits current geometry before and after scrolling. Pure SwiftUI ghost captures remain unchanged.
- [x] Focused final validation:19 parity/readiness tests passed, primary0/cleanup0, all tracked processes exited. Evidence: `space-parity-readiness-red.log`, `space-parity-all-native-scopes.log` under the task artifact directory. This proves the readiness defect and repair, without claiming exact reproduction of the historical26724-byte image.

The next run40758318040 passed all four native shards. Its worker-UA job failed only the named bare-engine discrepancy (four comparisons, primary1/cleanup0). Audit nevertheless found that whole-job advisory handling could also hide unknown assertions, setup/cleanup failures, and missing evidence.

- [x] Replace whole-job tolerance with strict classification of the exact named probe and six whitelisted startup/current comparisons. Require nonnil bare-engine identity, exact complete execution, matching assertion totals, fresh verified cleanup, and correct manifest/filter. Keep the actual XCTest comparisons unchanged.
- [x] Make that classified job a required aggregate dependency. Unknown failures and upload failures block merging; a passing sample still does not establish an identity repair.
- [x] Bundle the three exact nonempty evidence files into one archive, publishing only after successful creation; require its upload. Final offline verification:8 classifier/archive tests,9 unchanged shard tests,8227 gate states, actionlint and diff checks passed. Original run40758318040 raw fixture files are retained byte-for-byte with provenance.

## Latest-main integration qualification

Main advanced to5622c4a through PR547, overlapping the snapshot and DMG fixtures. Reconcile in a separate managed `ci-main-integration` checkout so the original checkout's active compact-window work stays preserved. Retain main's asynchronous image capture/cold-pin assertions and deterministic first-EBUSY control, with scoped population admission and ownership checks before every detach. Keep main's five-attempt bound.

A broader new-window cohort also exposed `incompleteHeartbeat` before its action test: launch readiness withdrew after the helper's first ready sample and fixed50ms delay. A controlled additional readiness gate reproduces the rejection while still requiring actual AppKit/launch checks. Replace that guessed delay with bounded re-observation after an executor yield using the same admission state; preserve final actual readiness and5s/12s bounds. The late readiness-loss negative control still fails at the original deadline.

- [x] Controlled lost-readiness RED→GREEN; seven admission policy/native tests passed, primary0/cleanup0.
- [x] Reconcile all three conflicts and audit the new cold-pin native capture. Replace FolderRollout's initial80ms guess with committed initial-row/owner admission; keep early-animation sample timing/outcomes unchanged.
- [x] Predeclare and complete three fresh owned-AppKit smoke +124-test repetitions. Every primary/cleanup status is0/0; each cohort has122 passes and two existing opt-in diagnostic skips. All50 password-autofill tests and exact selected coverage are verified. Preserve every attempt under `integration-5622c4a`.
- [x] One live DMG integration passed: injected first EBUSY recovered normally on verified-owned attempt2; final image/Finder assertions passed, no force, owned mounts/directories removed, pre-existing mounts unchanged.
- [x] Offline classifier/archive, shard, DMG lifecycle and8227 gate regressions/lint passed; all32 diagnostic/preflight processes exited.
- [ ] Independently review the combined shipping diff against5622c4a, pass new required CI, squash-merge, and verify actual main before calling CI repaired.
