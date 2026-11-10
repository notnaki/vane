# Ready Feature Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Publish the confirmed-ready resize, Library filtering and AI connection features together after the background work.

**Architecture:** Start from main `02a5c8d31c019b2edc816fb1db114613ccf1f9c1`, merge approved source branches, and cherry-pick the mandatory AI privacy repair. Preserve original branches and the previous aggregate; use one fresh combined review/build/full required CI.

**Tech Stack:** Swift 6, AppKit/SwiftUI, WebKit, Security/Keychain abstractions, offline Swift harnesses, XCTest.

**Spec:** Coordinator's explicit ready-batch scope freeze on 2026-11-10, with confirmed owner readiness and user UI approval.

## Global Constraints

- Exact source order: #622 `65b009821b55527c765e278f0a3c2c25ea5d6a7d`, #631 `3fe70138d41d88875774ae1fd1648ea6edebf3c6` (approved source `57d2cd77214c3e7d5cb6b58e16d0344b5c824d9c`), #633 `637dea23e175b0bf41961f44cab0bb3b56d3d89b`, then repair `f25649c6ffc9fba7b59ba4da4b543a71420e5c23`.
- The original #633 contains a known master-toggle stale-upload finding; the repair is mandatory, not optional evidence.
- Actual hosted Swift 6.3.3 compilation remains required for the endpoint Binding setter workaround. Local Swift 6.4 is not confirmation.
- Exclude website, onboarding #632, unfinished resize #618, MV2/iCloud, unresolved #616/#630 and unproven #635 F6 repair. Do not wait for their diagnostics.
- No original branch updates, duplicate watches/main monitoring, live accounts or personal Keychain data. Coordinate actual focus/capture intervals; builds/pure/unshown fixtures may run freely.
- No merge without central readiness gate, latest-main integration, exact review and all required checks. Previous aggregate/evidence and repair exports remain preserved.

## Review Focus

- Resize hover/drag layers must retain interrupted-animation lifetime, detent release and Reduce Motion/Battery Saver behavior.
- Library typography/metrics must retain profile filtering, private isolation and search-focus restoration in the approved column geometry.
- AI master off/on edges must invalidate stale cloud and local work through the actual production Binding; unchanged values must preserve fresh work.
- AI account/route/token-refresh changes must prevent stale/private uploads and preserve account-specific credentials and explicit cloud-summary consent.
- The compiler-safe explicit endpoint setter closure and existing background persistence/filter support must survive integration and hosted compilation.

### Task 1: Frozen source integration

- [x] Create isolated codex worktree at exact base, merge the three frozen heads in order and cherry-pick the mandatory repair.
- [ ] Verify source ancestry/repair patch equivalence and document any conflicts; consult affected owner if behavior changes.
- [ ] Record actual Swift/Xcode version in the existing CI toolchain step so the compiler gate has explicit evidence; no new workflow or dispatch.

### Task 2: Combined validation and review

- [ ] Run the five offline AI harnesses and focused resize/Library/model suites on the combined tree, with owned native cleanup.
- [ ] Coordinate a bounded compiled foreground fixture interval if relevant; otherwise retain scoped owner evidence and exercise those paths in hosted CI.
- [ ] Run pure selfcheck, source/workflow/diff checks, and obtain one fresh independent review of the entire exact combined diff.
- [ ] Fix actionable findings with retained red/green evidence; no opportunistic feature work or weakened assertions.

### Task 3: Publish and hold

- [ ] Push/open one batch PR linking original sources, user approvals, repair provenance, review and actual validation limits. Link immediately.
- [ ] Run one full required CI, verify actual Swift 6.3.3 evidence, and report exact head/PR/blockers to central coordinator.
- [ ] Hold merge for the central gate; preserve originals until verified integration and cleanup authorization.
