# MV3 navigator identity implementation plan

> **For agentic workers:** Use superpowers:executing-plans for inline implementation.

**Goal:** Repair #513's observable MV3 startup identity using a navigator bootstrap on system WebKit.

**Architecture:** Derive a bounded in-memory resource view from accepted code, create a versioned entry importing a synchronous bootstrap and unmodified canonical vendor resources, and initialize system WebKit through a guarded bridge. Keep all native host boundaries unchanged.

**Tech stack:** Swift 6, Objective-C, JavaScript, system WebKit, XCTest.

**Spec:** ../specs/2026-10-31-mv3-navigator-identity-design.md

## Global constraints

- macOS 26 minimum; system WebKit only.
- Original accepted resources/signatures and access remain intact.
- Identity snapshots belong to loaded contexts; identity changes rederive/reload MV3 contexts while preserving access, storage and IDs.
- A new blocking probe must establish the override independently of the historical native-UA advisory.

## Review focus

- Module imports execute before an entry body: bootstrap must run before dependency code.
- Classic strict/sloppy mode, BOM and directive ASI must remain native standalone-Script semantics.
- Resource traversal must retain containment and existing budgets for signed and folder sources.
- Recreated workers and restored contexts must preserve ownership/storage and current context identity.
- A missing SPI or malformed script must not become an apparently successful identity repair.

## Task 1: Qualify worker bootstrap and resource construction

- [x] Add blocking first-instruction classic/module tests and run them RED.
- [x] Add source-preservation, directive, import and bounded-resource tests, with RED evidence.
- [x] Add guarded native resource-initializer bridge and focused bootstrap/resource builder.
- [x] Route MV3 worker contexts through derived resources; leave other contexts on existing loading paths.
- [x] Run current canonical-wrapper tests GREEN and affected extension identity/compatibility/lifecycle tests.

## Task 2: Qualify lifecycle and delivery

- [x] Add worker recreation, reload with changed selection, host restore, storage and isolation assertions.
- [x] Repeat actual package and signed-fixture startup on the canonical-wrapper revision.
- [x] Remove known-issue/advisory machinery only after the blocking replacement establishes repair; update docs precisely.
- [x] Build assembled app and run focused native validation with verified cleanup.
- [ ] Commit, push, open PR, obtain independent current-diff review, fix findings and validate latest-target required CI.
- [ ] Squash merge only when all required gates pass; verify merge, retire test apps and archive worktree.

## Recorded implementation decisions

- Content-version worker URLs prevent native registration reuse after identity/code changes. Explicit wrappers are adjacent to the original entry; generated wrappers keep their virtual root. Canonical vendor module URLs and relative imports remain intact. Original disk files remain untouched.
- The early message-based startup probe was removed after it collided with vendor listeners. The production bootstrap only changes navigator getters; first-instruction proof comes from blocking native fixtures. Original failed attempts are preserved.
- The unmodified official Bitwarden Chrome 2026.10.0 startup check and signed MV3 exact-resource-seal case passed locally. A broader existing non-worker MV3 options-page readiness timeout is retained for investigation; no passing retry is considered a repair.
- Local native execution requires a coordinator lease. Merge requires per-PR coordinator clearance and no unfinished main CI run; never cancel a main run to bypass that hold.

- Independent review identified directive-parser escapes and query-distinct module-entry cycles. Pure Foundation/JavaScriptCore checks of the exact old method reproduced the strict-mode defect; an ECMAScript module check ran the entry twice. Both pure checks passed after replacing source rewriting with canonical import wrappers. Native regression cases are required before merge. Failed source/method fingerprints and all logs are preserved.

- The two review regressions also reproduced on native system WebKit at `a6587b8`, whose production tree is identical to `5f0c495`: two cases, five intended assertions, zero unexpected failures, primary1/cleanup0. Exact source/test-diff/binary hashes and the original log are preserved. The executed raw binary was replaced by the next build before the later preservation request; an identical-source rebuild produced different bytes, so raw-binary preservation is not claimed. Future native runs snapshot their executable before launch.

## Delivery integration and lifecycle review, 2026-11-01

The user authorized publishing and completing the PR/merge cycle after the CI landing. Source `34265f5` was integrated with main `c34d760` without conflicts; the shared retry fixture already matches main. Both PR and actual-main required CI for that preceding landing passed.

Independent review found a sequential-restart race: while restarting one worker, a completed replacement of a later worker could leave the updater holding its retired context. Capturing access from that context would overwrite the replacement's current grants and denials. A two-worker regression now suspends the first real restart, replaces the second worker, establishes different access, and waits for the complete update. After correcting the fixture's single-installation lookup assumption, the unmodified updater failed exactly the three context/grant/denial assertions; primary1/cleanup0. Both failed attempts, source diffs and raw test binaries are preserved.

The updater now verifies the exact current context and still-stale identity immediately before reserving a restart and capturing access. Three predetermined fresh-host regression attempts passed, then all 54 worker integration cases passed without skips, primary0/cleanup0. This includes the byte-verified official Bitwarden Chrome 2026.10.0 package and the Apple-signed MV3 resource-seal fixture. No original outcome deadline or security assertion changed. Source classifier/shard/workflow fixtures also passed (7 classifier cases, 10 shard cases, 2,078 workflow gate combinations). The debug app/test build and assembled sandboxed app build passed. Full latest-main required CI and final review remain delivery gates.

Full required run `41295996052` passed all four native shards, source fixtures and the shared build, but failed the standalone cold WebKit packaging probe: `WebKitStartup.swift` now imports `ExtensionResourceBridge`, while the probe still compiled Swift directly without that module. The same compilation failure was reproduced locally. The probe now compiles the actual production Objective-C bridge, exposes its unchanged header through a temporary Clang module map, and links it with the original Swift harness. The unchanged cold-start registry assertions and eight-second runtime deadline pass locally. A focused macOS 26 preflight must pass before another full required run; the failed run and logs remain preserved.

The cold probe passed source-pinned macOS 26 preflight `41297118827`. The subsequent full run `41297224548` passed packaging, source/build and native shards 1, 2 and 4, but shard 3 aborted in the existing action-window test with AppKit's excess window-layout-pass exception. Every shard's original artifacts are preserved. The earlier full run completed all 2,387 selected cases: 2,163 passes and 224 existing opt-in skips.

The popup content's layout callback synchronously called an animated native window resize. A controlled regression using the real SDK popup reproduces that inline frame mutation during a native window/layout operation. It fits the same provisional 400×500 content frame to the document's native 320×230 intrinsic size. The measured parent/provisional geometry gives x=270 and top=682; the original fatal 330×292 frame at (270,390) lies inside that popup's measured animation trajectory. Three old-source hosted owner observations in `41298760676` identify a separately positioned 260×304 permission dialog, while its controlled inline-resize assertion fails as expected, primary1/cleanup0. The association of the historical fatal window with the popup is a geometric inference, not an original identity receipt; the identical fatal exception has not been replayed.

Action fitting now runs in one deferred, coalesced main-actor task, measures the latest intrinsic size, suppresses repeated in-flight destinations, and verifies the exact live context/action/web/window before resizing. Closure and user resizing cancel pending work. Normal animation and Reduce Motion/Battery Saver behavior remain intact. The regression checks that fitting happens after native window/layout operations unwind and converges within the existing five-second deadline; a second case closes the exact owner before queued fitting can execute.

A later local cohort also exposed a foreground-admission prerequisite failure. A controlled real hide/reactivation case reproduced the missing step: making the window key left the application inactive, visible, and without a key owner. The fixture now explicitly requests activation and admits the exact visible key window, retaining all original outcome/security assertions and deadlines. An initial `deactivate()` control was ignored by the platform and is preserved separately as a fixture mistake. All failed attempts retain their logs, source diffs and raw test binaries. Three fresh local hosts completed the final 18-case Window/PageUI cohort: all 54 passed without skips, primary0/cleanup0. Three source-pinned macOS 26 hosts remain required before another full CI run. The 54 worker cases plus eight related page-UI cases also passed locally without skips, including the unmodified official Bitwarden package and signed resource-seal fixture, primary0/cleanup0.
