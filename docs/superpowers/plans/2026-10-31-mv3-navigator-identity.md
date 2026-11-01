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
