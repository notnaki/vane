# Browser Freeze Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Independent file ownership permits parallel work explicitly requested by the user. Root coordinates integration and independent review.

**Goal:** Remove every actionable whole-browser stall mechanism in the 23 October freeze audit and carry the fix through validation, PR review and squash merge.

**Architecture:** Keep AppKit/WebKit presentation on MainActor. Bound untrusted inputs before conversion; use linear parsing/indexes and bounded image decoding. Move expensive immutable IO/encoding/Keychain work to workers with explicit ordering, stale-result checks and failure propagation. Preserve atomic import/save and recovery guarantees.

**Tech Stack:** Swift 6, macOS 26+, AppKit/SwiftUI/WebKit, Foundation, SQLite, XCTest. No new dependencies.

**Spec:** User-approved freeze audit, supplied to workers at `/tmp/vane-freeze-audit-reference.md`; user explicitly requests fixing all findings, parallel subagents, review and merge.

## Global Constraints

- Work only in `/Users/nuh/.codex/worktrees/browser-freeze-fixes/vane` on `codex/browser-freeze-fixes`; preserve the primary checkout.
- No new dependencies; macOS minimum remains 26. Keep WebKit UI on MainActor.
- Preserve atomic save/import ordering, recovery originals, profile/private isolation, save-error reporting, cancellation and stale-document protections.
- Bound page-controlled payloads before expensive parsing; limits must reject safely without silently corrupting valid saved user data.
- Keep existing motion/Reduce Motion/Battery Saver policy.
- Tests use isolated synthetic data; no real browsing data or secrets. Track and clean any launched test app by PID/executable/start time.
- Workers own disjoint source files. Do not stage/commit, launch Vane, run global SwiftPM builds/tests, or edit another worker's file without coordination. Root integrates, compiles, runs suites and commits. Isolated standalone regression probes can be used for red/green before implementation.
- Full independent review and required CI/approvals must pass for the latest commit before squash merge; no review findings may be silently deferred.

## Review Focus

- Save/restore races: superseded background writes must never replace newer edits; quit/backup boundaries must flush or surface failure.
- Actor correctness: detaching must not share mutable SQLite/UI state unsafely or allow unrelated writes into an import transaction.
- Untrusted input: malformed HTML/entities, oversized messages, highly compressed images, cancellation and late document events fail safely.
- Failure paths: offline files, busy locks, unavailable Keychain and cancelled imports leave originals and UI responsive.
- Compatibility: existing CLI, pure checks and XCTest APIs retain behavior or get deliberate call-site updates.

## Tasks

### Task 1: Native page input boundaries
Files: Previews.swift, MediaPlayer.swift, Favicons.swift; focused new XCTest files.
- [ ] Reproduce malformed entity, pre-limiter sanitizer and large-pixel icon failures using exact-source probes before modifying behavior.
- [ ] Make entity decoding linear/bounded; cap bridge payloads early; apply media admission/limits before sanitization; safely downsample and bound favicon fetch/cache memory.
- [ ] Add regression coverage for valid metadata/entities, malformed input, rejection, pixels and cache behavior. Record commands and evidence.

### Task 2: Backup and updater IO
Files: Backup*.swift, Update*.swift, BundleReplacement.swift; main.swift updates coordinated with Task 7.
- [ ] Test that blocked snapshot/validation/update verification workers do not occupy MainActor, including failure/flush boundaries.
- [ ] Separate immutable capture from worker IO and validation; serialize restore/recovery operations without cross-profile/file interleaving.
- [ ] Run bundle hashing/signature verification/deletion off MainActor at startup/health confirmation; preserve rollback and clean-quit semantics.
- [ ] Add focused regressions and record evidence.

### Task 3: Easel and reading queue persistence
Files: Easel*.swift, Feel07*.swift, ReadingQueueStore.swift, Profiles.swift.
- [ ] Test large archive editing plus ordered persistence/failure behavior and queue deletion responsiveness.
- [ ] Move archive load/validation/encoding/write off UI with explicit ordered publication; avoid whole-library validation for unchanged boards; preserve undo and errors.
- [ ] Move recursive profile reading queue deletion off UI while preserving deletion/isolation semantics.
- [ ] Update owned callers and communicate any Engine or backup flush contract changes to root; add regressions.

### Task 4: Imports and exports
Files: Export.swift, Import.swift, BrowserImport.swift, ArcImport.swift, Store.swift.
- [ ] Add malformed/unclosed bookmark red regression and prove import/export processing can leave UI actor free.
- [ ] Replace pathological bookmark regex with linear tokenization or equivalent bounded parser, preserving validation and folder/date semantics.
- [ ] Move source reads/parsing, bulk SQLite operations and export formatting/writes off UI. Use a serialized destination design that preserves atomicity and does not lose concurrent normal history writes.
- [ ] Move CSV/Arc Keychain batches off UI; coordinate Passwords APIs with Task 6. Preserve CLI/errors/duplicate policy; avoid reparsing export just to count.
- [ ] Add focused correctness/cancellation/concurrent-write tests and record evidence.

### Task 5: Session, folder and Boost work
Files: Suspension.swift, RecoverySnapshots.swift, Folders.swift, SidebarRows.swift/cache if needed, SiteBoost*.swift. Engine/Window/Crash caller edits coordinated with Task 6/root.
- [ ] Guard responsive repeated sidecar saves with ordered writes and recovery/flush tests.
- [ ] Remove repeated sidecar decoding/unchanged rewrites and move large persistence IO off UI; communicate required async/flush callers.
- [ ] Index folder ancestry once per shape, retaining all visibility/lock semantics, with large shallow and cyclic/missing-parent regressions.
- [ ] Cache decoded Boost records, avoid three whole-library lookups, and move/debounce large serialization with ordering/error behavior; test profile isolation/invalidation.

### Task 6: Autofill and native Engine processing
Files: Passwords.swift, Engine.swift, password metadata helpers only as required; coordinate other file edits.
- [ ] Add stale-document and Keychain responsiveness tests with injected isolated workers.
- [ ] Run metadata/secret reads away from MainActor without changing origin/credential authorization; validate originating document/account after await.
- [ ] Move View Source escaping/build off UI and bound memory; preserve source-tab/document lifetime.
- [ ] Apply Task 5's agreed Engine session caller contract in saveCurrentSpace/switch paths; preserve session/backup flush ordering. Add focused regressions.

### Task 7: Blocker, icon and download IO
Files: Blocker*.swift, FilterSubscriptions.swift, AppIcon*.swift, Downloads.swift/DownloadLibrary.swift, icon helper if needed; coordinate main.swift with Task 2.
- [ ] Reproduce lock contention, large filter conversion and slow destination/ icon service without freezing test actor.
- [ ] Run bounded filter reading/conversion/persistence off UI; nonblocking/bounded cache lock handling and background orphan cleanup.
- [ ] Replace synchronous icon helper semaphore wait on app/UI path with async completion and ordered startup/settings handling.
- [ ] Move download external destination inspection off UI; publish identity-checked results without destroying file grants or invalidating resumable data.
- [ ] Add regressions and record evidence.

## Integration and acceptance

- [ ] Cross-check all 20 findings against changes, tests or a documented validated resolution; retain the ruled-out live-title finding as excluded.
- [ ] Root runs debug build, pure checks, full XCTest suite (broad concurrency/persistence change), focused helper/update/CLI checks, and release build/pure checks as justified.
- [ ] Generate per-task diff packages and obtain independent compliance/quality reviews; address every actionable finding and re-review amended code.
- [ ] Push branch; open PR with concrete behavior and validation; attach PR to chat.
- [ ] Independent whole-current-diff review; fixes and required CI/approvals pass at current head.
- [ ] Squash merge, verify PR merge and squash commit, clean tracked test processes/worktree, report results.
