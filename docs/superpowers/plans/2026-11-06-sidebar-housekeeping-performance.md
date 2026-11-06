# Sidebar housekeeping performance implementation plan

**Goal:** Make Clear responsive, remove the same delay from related Today bulk actions, and avoid repeated outline work during Tidy and Undo.

**Architecture:** Archive a snapshot of unlocked Today tabs synchronously, saving the archive once and removing each window's references in one completed mutation before retiring pages. Build Tidy's final shape locally before publishing. Retain short policy-aware animations, archive/reopen semantics, folder protection, splits and independent window selection.

**Tech stack:** Swift, Combine, SwiftUI, AppKit, XCTest.

**Spec:** User's Clear screen recording and request to fix Clear, Tidy and other evidenced sidebar lag.

## Constraints and review focus

- Preserve favourites, pins, locked folders, private browsing, archive metadata and reverse close order.
- Never resume a page being removed by the same bulk action; select a surviving split pane or Today neighbour once.
- Remove shared identities from live windows and stashes before tearing down their pages.
- Keep individual close behavior, native snapshot revocation, Reduce Motion and Battery Saver policy.
- Do not change AI grouping quality or its provider latency contract.

## Task 1: Bulk Today archive

- [x] Establish focused baseline and failing tests for synchronous Clear, one completed publication, archive ordering, locks, privacy, shared windows and final selection.
- [x] Add bulk archive persistence and reference removal; route Clear and related Today menu actions through it.
- [x] Verify focused tests and record before/after mutation counts and input duration.

## Task 2: Tidy publication

- [x] Add failing apply/undo tests for one completed sidebar invalidation and one final outline publication.
- [x] Build the shape off-store, publish it once with the finished order, and preserve undo and feedback.
- [x] Run focused native presentation tests and pure selfcheck.

## Delivery

- [ ] Open PR, obtain independent review, fix findings, pass required CI, and squash-merge after rechecking target CI.
- [ ] Preserve the final head, remove only this task's worktree, and verify test-process cleanup.

## Validation evidence

- Baseline: 8 focused tests passed. New tests reproduced delayed Clear, doomed-neighbour resumes, repeated Tidy publications and no-op shape publications.
- Final focused run: 57 tests, 1 opt-in timing test skipped, no failures; native retirement verified. Clear covers normal and Battery Saver motion policies.
- Pure selfcheck: PASS.
- Fixture corrections: shared windows need an explicit Space; a committed empty Today section has zero height, so the new receipt path explicitly requires zero height while preserving the ordinary positive-height rule.
