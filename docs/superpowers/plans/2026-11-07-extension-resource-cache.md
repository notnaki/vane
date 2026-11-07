# Extension Resource Cache Implementation Plan

> Use the executing-plans workflow for implementation and independent whole-branch review.

**Goal:** Remove the deprecated `WKProcessPool` and private scheme-revalidation dependency while preserving MV3 startup, canonical resource freshness, identity, permissions, and stored data.

**Architecture:** Prove public `WKWebsiteDataStore` memory-cache eviction refreshes canonical extension resources before a replacement context loads. Use WebKit's standard web-view configurations and validate repeated controller retirement, avoiding deprecated pool APIs and sharing of hidden configuration state. Preserve the immutable accepted resource view and content-derived worker entry paths.

**Tech stack:** Swift, Objective-C, system WebKit, native XCTest.

**Constraints:** macOS 26 minimum. Keep origins, identifiers, canonical vendor resource URLs, signed-resource verification and startup user agent unchanged. Never remove cookies, local storage, IndexedDB, service-worker registrations or extension storage as part of resource refresh. Await invalidation after retiring the old context, recheck operation lifetime, then load the replacement.

**Review focus:** Old-context requests racing cache eviction; cancellation while awaiting eviction; fresh configuration preferences/content controllers; profile-store isolation; repeated controller teardown.

- [x] Reproduce canonical module dependency staleness with private revalidation disabled, preserving the original failure log.
- [x] Test public memory-cache eviction before context loading against same-version and version-bumped dependency updates.
- [x] Replace deprecated pool construction/configuration with standard WebKit configuration lifetimes; remove obsolete capability checks and bridge declarations.
- [x] Extend update coverage to classic/transitive imports and storage preservation; preserve ownership and retirement assertions using configuration seeds.
- [ ] Run extension identity/lifecycle regressions and cold WebKit startup validation. Record limitations and cache-eviction performance cost.
- [ ] Review the current PR diff independently, resolve findings, pass required CI against current main, squash-merge, and clean up task worktrees/test processes.

## Evidence and decisions

- Diagnostic reproduction disabled private scheme revalidation while allowing startup: the existing same-version module update test executed `initial` rather than `updated`; log `/tmp/vane-extension-cache-research/no-revalidation.log`.
- Public memory-cache eviction passed both existing canonical module update variants with ordinary, unconfigured pools; log `/tmp/vane-extension-cache-research/public-eviction.log`.
- Removed explicit production pools. Repeated host/controller/context retirement passed with WebKit defaults, including fixture store retirement; log `/tmp/vane-extension-cache-research/default-context-retirement-fixed-build.log`.
- Cold registry startup passed without the pool bridge; log `/tmp/vane-extension-cache-research/cold-start.log`.
- Decision: standard configurations replace the proposed copied seeds because they pass the retirement regression and avoid sharing hidden visited-link/configuration state. Minimum-runtime CI remains required before merge.
- Public record lookup filters out custom extension origins, so eviction is limited by store and type, not by extension. Only memory resource cache is evicted; persistent site and extension data are retained.

Upstream references: [public store API](https://developer.apple.com/documentation/webkit/wkwebsitedatastore), [origin filtering](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/WebsiteDataRecord.cpp), [memory-cache eviction](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebProcess.cpp).

- Independent review identified a cancellation gap between the eviction callback and resumption of the load task. A real-store callback interception reproduced an untracked loaded context, then the final lifetime recheck made that exact test pass. Logs: `removal-after-cache-before-fix.log` and `all-resource-and-cancellation-fixes.log` in the research directory above.
- A new MV2 same-version update reproduced stale canonical background code when eviction was worker-only (`mv2-before-eviction.log`). Eviction now covers every managed context, preserving the prior scheme-wide cache behavior. MV2, MV3 document background, classic nested imports, module nested imports, same-version/bumped-version module updates, popup script refresh, stored values and cancellation-boundary cases all passed (7 cases).
- Signed focused preflight before that final scope fix: 107 tests, two opt-in package skips, zero failures, with 88 owned stores retired. The new classic fixture initially reused an invalid module-only URL assertion; corrected it to preserve classic `self.location` semantics and verified it passes. Full-suite validation of the final scope follows.

- Final broad local run: 2,491 tests, 55 skips, 12 failures across eight cases; cleanup passed, retiring owned stores after the primary host exited. Full log: `/tmp/vane-extension-cache-research/full-native.log`. Resource/cache/worker identity cases passed. Failed cases: `BrowserWindowTitleTests.testTitleSynchronizationReleasesClosedTab`, `EdgeSidebarScrollContinuityTests.testCreateEdgeCommitKeepsScrolledViewportUntilFormTakesOver`, `ExtensionNativeMessagingErrorTests.testCancellingNativeReviewCannotChangeTheAcceptedMode`, `PasswordAutofillTests.testInlineRevocationMetadataAwaitsProcessedUsernameBeforeRelease`, three `SpaceNativeRenderingTests` reveal/reuse cases, and `SpaceSelectionContinuityTests.testLatestClickReplacesAMountingSelection`.
- The first two failures are also preserved on unchanged baseline `bf5c8943` in `/tmp/vane-deprecations-baseline-preflight-3.log` (from the deprecation task). Additional baseline comparisons are underway; no unchanged passing retry is treated as a repair.
- The native-review policy failure occurs before extension loading. Its caller now supplies an explicit original activation-policy target to the existing bounded readiness loop, instead of racing an inferred snapshot against a preceding fixture's pending AppKit restoration. Outcome assertions and deadlines remain unchanged.
- Synthetic geolocation now binds its C provider to the actual test WebView's native context through existing test-only WebKit SPI, retaining the page until callback removal. It no longer constructs a deprecated process pool. Focused native validation follows.

- Unchanged-baseline comparison 1 completed 35 cases: title retention and edge-create commit failed again; native review, inline metadata revocation and selected Space rendering/selection cases passed once. This does not repair the additional full-run failures. Comparisons 2/3 could not start: the baseline test bundle disappeared between the first primary and cleanup. Cause not established; the deprecation agent confirmed it had not removed/rebuilt it.
- Cleanup recovery validated the original host/manifest, used the current compatible bundle at the required original path for retirement only, verified all 26 exact owned backend IDs absent and cleanup-host exit, then removed the manifest and copied cleanup-only bundle. Recovery is not baseline test evidence. Log: `baseline-retirement-recovery.log`; failed/empty attempts remain preserved.
- A final independent review of the production cache/cancellation diff reported no actionable findings. The later test-only geolocation and explicit AppKit policy changes still require focused validation/review.

- Final focused validation after the geolocation and explicit-policy changes: **162 tests, two opt-in package skips, zero failures**; cleanup passed and verified owned backend retirement (`final-focused-native.log`). Includes signed Safari fixtures, all resource update/cancellation cases, synthetic permission/geolocation tests and controlled AppKit policy-admission tests. App/test build passed (`final-test-build.log`); `git diff --check` passed.

- Rebuilt unchanged baseline `bf5c8943` in an isolated scratch path. Completed comparisons 2/3 reproduce the exact inline-metadata `InvalidTransition`, and comparison 3 reproduces latest-space-click selection failure; all cleanup passed. These remain existing failures, not repaired outcomes.
- Three complete baseline `SpaceNativeRenderingTests` repetitions are preserved in `baseline-space-class-{1,2,3}.log`. Run 1 passed; later runs showed other baseline native rendering/landing failures. The three reveal/reuse failures from the broad current-tree run were not reproduced, so that full-suite validation gap remains open. Every primary and cleanup host exited; the desktop was explicitly released to the deprecation agent for #604's F6 failure reproduction.
- Published draft PR #607, head `610545dd29c5b34bc30e27c54b71d88279c46151`. Its source/build/packaging and native shards 1–3 passed. Shard 4 in run `42361462273`, job `128371841495`, traps with signal 5 on macOS 26.7.2 during the new cache-completion/removal fixture. The available Swift stack shows XCTest/run-loop frames, not a proven root cause. Evidence is preserved under `ci-native4-artifacts` in the local research directory. No unchanged retry is treated as resolution.
- Diagnostic-only branch `codex/extension-cache-preflight`, commit `13a823df`, adds callback markers and a manually dispatched focused macOS 26 workflow. It is not part of PR #607 and must not be merged. Run `42362835571` built the exact instrumented tree but completed only the first of three planned repetitions: inherited bash errexit stopped the loop on failure. It preserved callback/system logs; no crash report was available. The new removal fixture completed and passed before a later restore case trapped after cache invalidation. The original buffered test location did not establish the crash origin.
- #604's owner confirmed the only blocker there is F6 focus handoff in `KeyboardAccessibilityTests.testF6LeavesTheLocalEaselForBrowserControls`, run `42360388128` shard 1. Intended order remains #604 first, then rebase #607; the owner will explicitly notify this thread when fixed and merged.

### Integration after #604

- #604 merged as `a4866249ba5d11e5c78d22a5709072922d9a4575`, following green required run `42363292956`. Rebased this branch onto it and resolved seven conflicts. Removed the obsolete process-pool adapter and its ownership test, while retaining `VaneSetBooleanPreference` and all six Boolean adapter tests. Local rebuilt sanity validation passed seven cases, primary 0 / cleanup 0.
- Rejected a public initialized-configuration template experiment after independent review found that copying the templates also shares hidden visited-link state across profiles/private pages. The experiment is stashed and absent from the implementation. Its local attempt crashed in Swift task allocation at the first case; no passing result is claimed.
- Diagnostic branch `a14657c8` uses the rebased implementation, callback instrumentation, a tested LLDB driver, and three predetermined attempts with errexit disabled. Its purpose is to capture the actual minimum-runtime crash stack. Diagnostic workflow/driver/instrumentation remain separate from this PR.
- Baseline source worktree is no longer needed; every baseline primary/cleanup host exited, with dedicated `/tmp/vane-extension-cache-research/baseline-build` evidence retained.

### Page-scoped controller retirement

- Run `42364623465`, diagnostic head `a14657c8`, completed all three predetermined attempts. Each stopped at `IPC::MessageReceiverMap::invalidate()` from `WebProcessPool::~WebProcessPool()` / `WebProcessProxy::~WebProcessProxy()`, primary 1 / cleanup 0. Full stacks and logs are preserved in `lldb-preflight-diagnostics`. This is native receiver retirement, not a Swift actor assertion in the swizzled callback.
- Upstream WebKit [825d9df3072f](https://github.com/WebKit/WebKit/commit/825d9df3072f) fixes missing controller receiver cleanup; the upstream diagnosis is explicitly speculative about receiver identity. Our matching stack does not by itself establish every receiver involved.
- New real-page lifetime regression failed before the repair: the controller was nil while its background view remained alive. Tracked extension views now retain their controller through native teardown, while existing explicit unload paths break the active context/page/controller cycle. The controller does not retain the host. No shared configuration, visited-link state or deprecated pool API is introduced.
- Local focused validation passed 15 startup/lifetime cases, primary 0 / cleanup 0, with all 15 exact owned backends absent. Independent review of the combined diff against `a4866249` found no actionable findings, including unload paths and Boolean-adapter preservation.
- Minimum-runtime repair preflight `42365430291`, diagnostic head `284e76d8`, runs three predetermined repetitions using the exact production/test source with diagnostic markers and debugger disabled. A full local suite on the repaired, rebased tree is also running; neither pending run is claimed green.

- #606's owner reported one overlapping eight-case edge preflight on this desktop at 13:48:15–13:48:28 Istanbul, with its host exited and cleanup passed. Preserve the full local run's affected interval as contaminated evidence; do not claim an uncontaminated full-suite pass from it. #606 owns the next desktop slot after this primary plus cleanup exit, for three predetermined 79-test rounds. No further local native/build work is queued before its explicit release.
