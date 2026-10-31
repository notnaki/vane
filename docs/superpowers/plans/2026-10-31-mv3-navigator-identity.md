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
- [ ] Run current canonical-wrapper tests GREEN and affected extension identity/compatibility/lifecycle tests.

## Task 2: Qualify lifecycle and delivery

- [x] Add worker recreation, reload with changed selection, host restore, storage and isolation assertions.
- [ ] Repeat actual package and signed-fixture startup on the canonical-wrapper revision.
- [ ] Remove known-issue/advisory machinery only after the blocking replacement establishes repair; update docs precisely.
- [ ] Build assembled app and run focused native validation with verified cleanup.
- [ ] Commit, push, open PR, obtain independent current-diff review, fix findings and validate latest-target required CI.
- [ ] Squash merge only when all required gates pass; verify merge, retire test apps and archive worktree.

## Recorded implementation decisions

- Content-version worker URLs prevent native registration reuse after identity/code changes. Explicit wrappers are adjacent to the original entry; generated wrappers keep their virtual root. Canonical vendor module URLs and relative imports remain intact. Original disk files remain untouched.
- The early message-based startup probe was removed after it collided with vendor listeners. The production bootstrap only changes navigator getters; first-instruction proof comes from blocking native fixtures. Original failed attempts are preserved.
- The unmodified official Bitwarden Chrome 2026.10.0 startup check and signed MV3 exact-resource-seal case passed locally. A broader existing non-worker MV3 options-page readiness timeout is retained for investigation; no passing retry is considered a repair.
- Local native execution requires a coordinator lease. Merge requires per-PR coordinator clearance and no unfinished main CI run; never cancel a main run to bypass that hold.

- Independent review identified directive-parser escapes and query-distinct module-entry cycles. Pure Foundation/JavaScriptCore checks of the exact old method reproduced the strict-mode defect; an ECMAScript module check ran the entry twice. Both pure checks passed after replacing source rewriting with canonical import wrappers. Native regression cases are required before merge. Failed source/method fingerprints and all logs are preserved.

- The two review regressions also reproduced on native system WebKit at `a6587b8`, whose production tree is identical to `5f0c495`: two cases, five intended assertions, zero unexpected failures, primary1/cleanup0. Exact source/test-diff/binary hashes and the original log are preserved. The executed raw binary was replaced by the next build before the later preservation request; an identical-source rebuild produced different bytes, so raw-binary preservation is not claimed. Future native runs snapshot their executable before launch.
