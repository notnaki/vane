# Background Limitations Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Publish the independent filter-refresh and history-save improvements first, without waiting for personal UI design approval.

**Architecture:** Preserve exact #625 and #629 source commits through ordered merges on a new codex branch from main `196278148f26a44397cd0d4468c5465fc9c6c29e`. Retain the superseded five-feature aggregate separately. The original PRs remain open until this batch actually merges.

**Tech Stack:** Swift 6, WebKit, SQLite, AppKit/SwiftUI recovery controls, XCTest.

**Spec:** Coordinator's user-priority change on 2026-11-10: first publish ONLY #625 and #629, including their associated controls/docs; focused combined validation, fresh final-background-diff review, one full required CI, and coordinator-gated eventual squash merge.

## Global Constraints

- Exact source heads: #625 `c6e9e7a7a12a84205cbe8f6e0fa42c6462c853a8`, then #629 `2b9019fdba5d6ae13779cb40ade6ed38355df9e9`.
- Exclude #633/#622/#631, draft-gated #618/#632, unresolved #616/#630, and website changes from this first diff.
- No original branch pushes/base updates or original full-CI reruns. No cancellation of main.
- No personal-account, Keychain or foreground/input/capture validation. Keep original assertions and failure evidence.
- Sync/passkeys remain excluded. No new feature behavior or opportunistic edits.
- Coordinator owns main-run completion monitoring and final merge release; do not duplicate it.

## Review Focus

- Failed linked-file reads, compilation or persistence must retain last-good active rules and consent boundaries.
- Equivalent badfilter normalization must not broaden exclusions or conflate WebKit resource buckets.
- Failed visit/title writes must preserve original time and suffix order, including later Clear History.
- Save-state feedback must remain profile-correct, headless-safe, and distinct from durable history publication.
- Quit/backup must drain retained writes or refuse, without claiming in-memory retries survive a crash.

### Task 1: Preserve exact source provenance

- [x] Create the new isolated task worktree at the exact main base.
- [x] Merge exact #625 then #629, preserving all source commits and original PRs.
- [x] Verify the diff contains only those changes and this provenance plan; no conflicts or manual feature edits.

### Task 2: Focused validation and fresh review

- [ ] Run the combined blocker/history/import/search/data-fidelity native wrapper with owned cleanup; run pure selfcheck and diff checks.
- [ ] Obtain fresh independent review of the entire exact background base-to-head diff. Preserve useful superseded review evidence without treating it as approval of this scope.
- [ ] Fix actionable findings with evidence before publishing; retain all failures and outcomes.

### Task 3: Publish one background PR

- [ ] Push/open a batch PR linking #625 and #629 and carrying source validation/limitations; link immediately and run one full required CI.
- [ ] Report exact branch/worktree/head/PR and blockers to the coordinator; watch only the batch PR.
- [ ] Merge only after coordinator release, exact-head review, latest-main integration, all main/PR checks, and existing protections pass. Keep originals open until then.
