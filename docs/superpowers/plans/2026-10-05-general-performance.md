# General Performance Implementation Plan

> Implement in this session using the performance and debugging workflows, then obtain an independent review of the final PR diff.

**Goal:** Reduce measured main-thread pauses in populated sessions during focus changes, shared-tab cleanup, and sidebar rendering.

**Architecture:** Build indexes local to each operation rather than caching mutable tab state. Preserve object identity for page ownership and first-match, ordered UUID identity for sidebar rows. Keep existing snapshot generations and asynchronous transfer guards.

**Tech stack:** Swift 6, AppKit, SwiftUI, WebKit, XCTest.

## Constraints and review focus

- Keep tab order, collapsed folder depth, split lead rules, and stale-ID filtering unchanged.
- Distinct restored objects with the same UUID must remain distinct ownership candidates.
- Stashes can repeat a tab in one window or retain a page after another window closes.
- Keep key-window, visible-owner, hidden-owner priority and snapshot invalidation intact.
- Do not create web views to resolve rows or refresh presentation.
- Preserve unrelated checkout changes; use `codex/general-performance` and the project PR/review/squash workflow.
- Track and quit only task-owned packaged browser test instances after merge.

## Task 1: Index ownership and retained pages

Files: `Sources/Vane/SharedTabs.swift`, `Tests/VaneTests/SharedPresentationTests.swift`, `Tests/VaneTests/GeneralPerformanceTests.swift`.

- [x] Benchmark 10 refreshes at 100, 500, and 1,000 blank tabs before changes.
- [x] Reproduce the excessive cost with a generous 500 ms regression budget for 10 refreshes; baseline fails at 1.094 s.
- [x] Build an ordered unique-UUID tab list and an object-identity-to-window-index lookup, reading each window's complete strip/stashes once.
- [x] Resolve visibility and key-window state once per refresh and retain the existing `claim` implementation.
- [x] Resolve retained object identities once per release and once after each shared-state reconciliation.
- [x] Cover visible key/owner/hidden priority, snapshot generation, repeated stash membership, duplicate-ID objects, and pages retained by another window's stash.
- [ ] Run targeted and full tests plus real WebKit shared-window smoke assertions.

## Task 2: Resolve sidebar rows once per render

Files: `Sources/Vane/SidebarRows.swift`, `Sources/Vane/UI.swift`, `Tests/VaneTests/SidebarRowsTests.swift`, `Tests/VaneTests/GeneralPerformanceTests.swift`.

- [x] Benchmark the original exact row-filtering loop; 10 passes over 1,000 tabs take 1.582 s.
- [x] Build a first-match string-ID-to-live-tab lookup and resolve split leads once per section render through the existing `Split.lead` rule.
- [x] Return rows carrying their `Pins.Visible` metadata and optional live tab reference; use the same resolved reference in `ShapeRow`.
- [x] Cover section order, nested/collapsed folders, stale IDs, strip order versus pane order, favourites, duplicate IDs, overlapping splits, and fresh snapshots after mutations.
- [x] Measure final row preparation and keep the generous regression budget: 10 passes at 1,000 tabs now take 20.6 ms; ownership refresh takes 28.6 ms.

## Validation and delivery

- [x] Run README debug build, pure selfcheck, all 199 Swift tests, icon/cloud checks, CLI import, CI/release workflow fixtures, app bundle, default-browser prompt, DMG, and update-installer checks.
- [ ] Build release, run release pure selfcheck, and run tracked packaged WebKit smoke tests.
- [ ] Push task-only changes, open and attach the PR, obtain independent review of the current head, fix findings and rerun affected checks.
- [ ] Confirm required CI and mergeability, squash-merge, verify merge SHA, and verify all tracked test processes exited.
