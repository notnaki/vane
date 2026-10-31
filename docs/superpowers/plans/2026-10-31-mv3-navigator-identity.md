# MV3 navigator identity implementation plan

> **For agentic workers:** Use superpowers:executing-plans for inline implementation.

**Goal:** Repair #513's observable MV3 startup identity using a navigator bootstrap on system WebKit.

**Architecture:** Derive a bounded in-memory resource view from accepted code, inject a synchronous classic bootstrap or first module import, and initialize system WebKit through a guarded bridge. Keep all native host boundaries unchanged.

**Tech stack:** Swift 6, Objective-C, JavaScript, system WebKit, XCTest.

**Spec:** ../specs/2026-10-31-mv3-navigator-identity-design.md

## Global constraints

- macOS 26 minimum; system WebKit only.
- Original accepted resources/signatures and access remain intact.
- Identity snapshots belong to loaded contexts; identity changes rederive/reload MV3 contexts while preserving access, storage and IDs.
- A new blocking probe must establish the override independently of the historical native-UA advisory.

## Review focus

- Module imports execute before an entry body: bootstrap must run before dependency code.
- Classic strict/sloppy mode, BOM and directive ASI must not be changed by insertion.
- Resource traversal must retain containment and existing budgets for signed and folder sources.
- Recreated workers and restored contexts must preserve ownership/storage and current context identity.
- A missing SPI or malformed script must not become an apparently successful identity repair.

## Task 1: Qualify worker bootstrap and resource construction

- [x] Add blocking first-instruction classic/module tests and run them RED.
- [x] Add source-preservation, directive, import and bounded-resource tests, with RED evidence.
- [x] Add guarded native resource-initializer bridge and focused bootstrap/resource builder.
- [x] Route MV3 worker contexts through derived resources; leave other contexts on existing loading paths.
- [x] Run new tests GREEN and affected extension identity/compatibility/lifecycle tests.

## Task 2: Qualify lifecycle and delivery

- [x] Add worker recreation, reload with changed selection, host restore, storage and isolation assertions.
- [x] Exercise actual package startup with unmodified accepted sources where fixtures are available.
- [ ] Remove known-issue/advisory machinery only after the blocking replacement establishes repair; update docs precisely.
- [ ] Build assembled app and run focused native validation with verified cleanup.
- [ ] Commit, push, open PR, obtain independent current-diff review, fix findings and validate latest-target required CI.
- [ ] Squash merge only when all required gates pass; verify merge, retire test apps and archive worktree.

## Recorded implementation decisions

- Content-version worker URLs prevent native registration reuse after identity/code changes. Explicit entries retain paths and relative imports; generated workers import original scripts from a versioned wrapper. Original disk files remain untouched.
- The early message-based startup probe was removed after it collided with vendor listeners. The production bootstrap only changes navigator getters; first-instruction proof comes from blocking native fixtures. Original failed attempts are preserved.
- The unmodified official Bitwarden Chrome 2026.10.0 startup check and signed MV3 exact-resource-seal case passed locally. A broader existing MV2 retry-page readiness timeout is retained for investigation; no passing retry is considered a repair.
- Local native execution requires a coordinator lease. Merge requires per-PR coordinator clearance and no unfinished main CI run; never cancel a main run to bypass that hold.
