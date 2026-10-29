# Recent Feature Requests Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, followed by independent whole-diff review. Track each deliverable below.

**Goal:** Implement #552–#555 in the existing native app.
**Architecture:** Extend profile preferences, reuse a single symbol-or-emoji renderer, preserve the Space order store, and reuse native upload ownership for extension views.
**Tech Stack:** Swift, SwiftUI, AppKit, WebKit, XCTest.
**Spec:** docs/superpowers/specs/2026-10-29-feature-requests-library-design.md

## Global Constraints

- macOS 26+, system WebKit, no added dependencies.
- Preserve native appearance and profile isolation.
- Respect Reduce Motion and Battery Saver.
- Required latest-integration CI and independent review before squash-merge.

## Review Focus

- A password lookup completes after saving is disabled: no offer or store write.
- Emoji contains variation selectors or a joined family: preserve one grapheme.
- A stale or foreign Space drag: no cross-profile order mutation.
- A cross-profile hop: dismiss Library on both actual stores.
- Extension disable/window close while a file sheet is open: complete once with cancellation.

### Task 1: Password-save preference (#555)

**Files:** Passwords.swift, PasswordsUI.swift, Engine.swift; PasswordSavePreferenceTests.swift.
**Interfaces:** Profile-keyed preference reader/setter used by submission admission, read completion, and commit admission.
- [x] Add tests for default/profile isolation, disabled submission, in-flight completion and staged commit rejection.
- [x] Run focused tests and confirm the missing behavior fails.
- [x] Add preference and toggle; cancel/dismiss active offers when disabled and recheck at async boundaries.
- [x] Run PasswordSavePreferenceTests and related save/service tests; commit.

### Task 2: Emoji Space icons and Arc import (#553)

**Files:** Spaces.swift, new SpaceIcon.swift, SpaceIconPicker.swift, SpaceEmojiCatalog.swift and SpaceEmoji resource, ArcImport.swift, Space/Library/theme/menu/search views; SpaceIconTests.swift.
**Interfaces:** Shared symbol-or-emoji rendering; ArcSpace optional icon metadata.
- [x] Add grapheme/import/persistence/rendering regression cases; confirm failures.
- [x] Add shared renderer/native image support, the referenced Emoji/Icon picker with search/categories/reset and bundled Unicode data, and Arc metadata preservation.
- [x] Run SpaceIconTests and related Arc/footer tests; commit.

### Task 3: Library navigation and reordering (#554)

**Files:** LibraryWindow.swift, SpacesUI.swift; LibrarySpaceInteractionTests.swift.
**Interfaces:** Library.show closes both stores on success; validated Space UUID drag uses existing reorder persistence.
- [x] Add same-profile, invalid/stale and profile-hop navigation tests and reorder-boundary cases; confirm failures.
- [x] Dismiss Library after successful show and add an accessible footer drag handle and guarded reorder drop.
- [x] Run LibrarySpaceInteractionTests and relevant Library tests; commit.

### Task 4: Extension file selection (#552)

**Files:** Extensions.swift, Uploads.swift, new extension view UI delegate if needed; ExtensionPageUITests.swift.
**Interfaces:** FileUploads chooser accepts request identity/current-owner closure, shared with tab path.
- [x] Add native fixture exercising an actual file input in an options page and popup; confirm missing delegate failure.
- [x] Retain UI delegate and cancel panels on navigation, close, disable or teardown; preserve upload guards.
- [x] Run focused extension/upload tests; commit.

### Task 5: Integration and delivery

- [x] Update user guides, build, run focused combined tests and inspect native UI.
- [ ] Push branch and create/attach PR with issue links and validation.
- [ ] Obtain independent exact-head review; fix and revalidate actionable findings.
- [ ] Confirm strict/enforced required checks and latest main integration; squash-merge only when all gates pass.
- [ ] Verify merged commit, retire tracked app processes, archive this task’s worktree and report results.
