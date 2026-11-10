# Remaining Limitations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Implement the five accepted limitation improvements through four independent changes.

**Architecture:** Reuse existing blocker transactions, isolated-world autofill, WebKit extension contexts and Arc cookie/decryption primitives. Each independent implementation runs in a prepared isolated checkout and returns a focused PR; the parent reviews and integrates in sequence.

**Tech Stack:** Swift 6, AppKit/SwiftUI, WebKit, SQLite, CommonCrypto/Security, XCTest.

**Spec:** docs/superpowers/specs/2026-11-10-remaining-limitations-design.md

## Global Constraints
- macOS 26+, existing Swift package and public WebKit contracts.
- Sync and passkeys remain excluded; no real-account, personal cookie or Keychain fixture access.
- Preserve last-good filtering, explicit consent, exact origin/profile/private boundaries and truthful error reporting.
- Never touch other tasks' preview apps or steal foreground/input ownership.
- Parent handles independent review, current-main CI, merge and cleanup; children stop at validated PRs.

## Review Focus
- Atomic replacement or disappearance of a linked filter file must retain valid accepted rules and recover after repair.
- New filter syntax must not convert exclusions into broader blocking or hiding.
- Shadow-root ancestors and replaced documents must not bypass hidden/inert/origin/field-token checks.
- Sidebar extension actions must target the clicked tab, including when selection changes or it closes.
- Cookie imports must not strip security attributes, overwrite existing sessions, read wrong browser keys or leak decrypted values.

### Task 1: Local source refresh and additional EasyList support
**Files:** Sources/Vane/Blocker.swift, BlockerSettings.swift, FilterSubscriptions.swift or new LocalFilterSources.swift, main.swift; Tests/VaneTests/Blocker*Tests.swift and new source-store tests; blocker user docs.
**Interfaces:** Retain Blocker.convert/convertBoundedSources and the serialized compile gate; expose a linked-source manager to Settings and startup. Keep existing disk snapshot semantics.
- [x] Write failing tests for opt-in linkage, changed/unchanged source, deletion/replacement, invalid UTF-8/oversize/zero usable rules, compile/save failure and relaunch recovery.
- [x] Implement bounded off-main path polling after opt-in linkage, explicit linking/removal controls, last-good snapshot transactions and error/retry status. Polling runs every 30 seconds and on startup/wake; Check Now also works when automatic refresh is paused.
- [x] Select and implement at least two useful additional exactly representable filter constructs after failing conversion/behavior tests; preserve diagnostics for unsupported cases.
- [x] Run focused wrapper tests, real WebKit conversion behavior and pure selfcheck; commit and open a focused PR.

### Task 2: Open-shadow and multi-step autofill
**Files:** Sources/Vane/PasswordAutofill.swift and relevant password integration code; Tests/VaneTests/PasswordAutofillTests.swift and related boundaries; PASSWORD-MANAGER.md.
**Interfaces:** Preserve __vaneFill methods/message contracts, native authorization, document and field tokens; extend discovery/traversal internally.
- [x] Write failing real-WebKit tests for open-shadow login discovery/fill/capture, dynamic insertion, nested roots, multi-step username/password handoff, and inaccessible/hidden/inert/ambiguous refusals.
- [x] Implement composed-tree traversal, deep focus/event handling and bounded dynamic discovery without weakening origin/visibility/private restrictions or auto-submitting.
- [x] Run focused autofill and password boundary suites; record untested account/UI boundaries, commit and open a focused PR.

### Task 3: Extension actions on sidebar tab menus
**Files:** Existing extension menu integration, sidebar menu owner, ExtensionDiagnostics.swift and ExtensionConsent.swift; new/focused extension tests and integration docs.
**Interfaces:** Reuse WebKit's public extension menu APIs and existing extension-tab adapter; supply the clicked tab explicitly.
- [x] Write failing tests for clicked-unselected tab targeting, selected-tab change, tab closure, extension unload, profile/private isolation, disabled/empty items and non-tab rows.
- [x] Wire extension submenus into native/SwiftUI sidebar tab menus with consistent ordering and existing permission review behavior; update diagnostics/copy only for implemented support.
- [x] Validate focused menu/extension tests without using foreground capture; commit and open a focused PR.

### Task 4: General Chromium session import
**Files:** BrowserImport.swift, ArcImport.swift, new shared Chromium cookie/decryption helpers as needed, import review UI; synthetic cookie/import tests and DATA-AND-PRIVACY.md.
**Interfaces:** Retain atomic history/bookmark import APIs; add an explicit optional cookie import path, browser-specific Safe Storage selection and accurate category counts.
- [x] Write failing tests using synthetic SQLite cookie schemas and injected secrets: supported browsers, AES/decryption/schema variants, attributes, expired/partitioned/unsupported rows, destination collision, cancellation, wrong profile and store failures.
- [x] Extract reusable Arc primitives where needed; implement opt-in session review/import for supported Chromium profiles, preserving existing destination cookies and reporting partial failures without overstating restored sign-ins.
- [x] Run focused cookie/Arc/general-import and private-isolation suites with synthetic fixtures; commit and open a focused PR.

### Parent integration
- [x] Review each exact PR head independently, fix actionable findings and revalidate relevant behavior.
- [ ] Integrate against current main, run required full CI, wait for separate unfinished main runs and squash-merge when all requirements pass.
- [ ] Verify merged commits, stop obsolete watches and clean up task-owned artifacts while retaining managed/uncertain worktrees and user data.

## Integration status on 2026-11-10

Feature PRs: #624 sidebar menus, #625 linked filters/EasyList, #626 shadow/multi-step
autofill, #628 Chromium sessions. Independent reviews found and prompted regression
fixes for equivalent badfilter identity, external form associations, contradictory
cookie lifetimes and ambiguous stored values. Final current-head review and required
CI gate their sequential merges; they are not marked merged by this plan.

The parent also added navigation-history failure retention and Retry Save (#629),
validated by 74 focused tests and pure selfcheck. Its current-main rerun and final
review are tracked with the same integration gate. #629's feature documentation
depends on #624/#625/#626/#628 merging first.
