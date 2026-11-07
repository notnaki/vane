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
