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
- [ ] Run the focused live background/restore/update controls and independent review before proposing this repair for integration.

Local focused result: 34 passed, primary 0 / cleanup 0. Independent review and required CI are the remaining integration gates.

## Task 2: Identify and repair the remaining Bitwarden popup failure

- [x] Reuse verified vendor resources read-only; create fresh task-owned copies and record their digests/provenance.
- [ ] Exercise the actual installer, anchored popup, close/reopen and fresh-process restoration in a signed isolated app, without credentials.
- [ ] Preserve the original 20-second welcome/control/identity verdict. If it fails, identify the executing document and API/JavaScript boundary before proposing a fix; post-failure inspection cannot change the verdict.
- [ ] Add a deterministic regression for any demonstrated host defect, then run uninstrumented real-package acceptance. Exact Store provenance remains a distinct acceptance requirement.

Current result: actual anchored-popup welcome JavaScript still times out at 20 seconds after successful installation. Renderer sampling finds a microtask loop, but has not identified its JavaScript document/cause. Post-failure, preattached-clone, and background-inspector diagnostics are separate non-acceptance arms. Original failures and positive scoped-store retirement logs are preserved. No popup repair is established.

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
