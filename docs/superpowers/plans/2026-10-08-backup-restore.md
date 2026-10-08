# Backup and Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export Vane's complete saved library, preview replacement restores, and automatically preserve local recovery points.

**Architecture:** A versioned binary plist archive holds owned file snapshots and a preference plist. A library adapter captures SQLite through its backup API and validates all payloads. A durable launch-time transaction replaces owned files and preferences with rollback; Settings and hourly recovery use these shared services.

**Tech Stack:** Swift 6, macOS 26, Foundation, CryptoKit, SQLite3, AppKit, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-08-backup-restore-design.md`

## Global Constraints

- Support macOS 26 or later.
- Use only Foundation, CryptoKit, SQLite, and the app's existing UI frameworks; add no dependency.
- Bound archive reads to 512 MiB and total decoded payloads to 512 MiB; report the limit without trimming any requested data.
- Restore does not merge libraries.
- Capture only Vane's own persistent domain, never global or registered defaults.
- Never change the user's quit-confirmation preference.
- Keep the latest ten completed points total, ordered by creation time with unique IDs for ties.
- System Reduce Motion and Battery Saver make UI transitions immediate.
- Preserve unrelated files, migration markers, and recovery storage; isolate all task testing with VANE_DATA_DIR and scratch preference suites.

## Review Focus

- A damaged current library must still accept a valid incoming restore and preserve its damaged originals; cover in Task 3.
- Optional files absent from a backup must remove corresponding current owned files without deleting unrelated files; cover in Task 3.
- A changed backup file after preview must not change staged bytes; cover in Tasks 3 and 5.
- Duplicate URLs, cross-window tab sharing, and favourite/pinned/session overlap must not inflate preview counts; cover in Task 2.
- Failed automatic writes/pruning must preserve the last usable point and keep its status honest; cover in Task 4.

---

### Task 1: Archive codec and path ownership

**Files:**
- Create: `Sources/Vane/BackupArchive.swift`
- Create: `Tests/VaneTests/BackupArchiveTests.swift`

**Interfaces:**
- Consumes: Foundation Data and CryptoKit SHA256.
- Produces: `BackupArchive: Codable, Sendable`, `BackupArchive.File: Codable, Sendable`, `BackupReason: String, Codable, Sendable` (`manual`, `automatic`, `beforeRestore`), `BackupCodec.encode(_:) throws -> Data`, `BackupCodec.decode(_:) throws -> BackupArchive`, `BackupCodec.read(_:) throws -> BackupArchive`, `BackupCodec.write(_:to:) throws`, `BackupPaths.isOwned(_:) -> Bool`, and `BackupPaths.names(for:) -> Set<String>`.
- Archive fields: format identifier, version, id, created, appVersion, reason, preferences Data, preference digest, files `[File]`; File fields: name, data, SHA256 digest. Capture excludes local bookkeeping. Names are allowlisted profiles.json, per-profile spaces/session/spacestate JSON, Easel JSON, profile databases, and FilterLists entries with validated imported list names.

- [ ] **Step 1: Write codec rejection and round-trip tests.** Use small immutable payloads; decoding enforces format/version, size, uniqueness, flat owned names, and digests before any library I/O.

```swift
func testRoundTripPreservesPayloadBytes() throws {
    let archive = BackupArchive(preferences: Data("settings".utf8),
        files: [.init(name: "profiles.json", data: Data("profiles".utf8))])
    let copy = try BackupCodec.decode(BackupCodec.encode(archive))
    XCTAssertEqual(copy.files.first?.data, archive.files.first?.data)
    XCTAssertEqual(copy.preferences, archive.preferences)
}
func testTraversalAndDuplicateEntriesAreRejected() throws {
    for names in [["../profiles.json"], ["/profiles.json"],
                  ["profiles.json", "profiles.json"], ["Recovery/file"]] {
        let archive = BackupArchive(preferences: Data(), files: names.map {
            .init(name: $0, data: Data())
        })
        XCTAssertThrowsError(try BackupCodec.decode(PropertyListEncoder().encode(archive)))
    }
}
```

Add tests for altered file/preference digests, future version, malformed plist,
the boundary helper without allocating 512 MiB, symlink reads, imported FilterLists
names versus traversal/nested paths, exact profile-name
rules (default suffix versus UUID suffix, Easel uppercase UUID), and failed atomic
export preserving an existing file. Add a writer injection seam for I/O failures.

- [ ] **Step 2: Run `swift test --filter BackupArchiveTests` and observe failure because the new types do not exist.** Expected: compilation failure naming BackupArchive/BackupCodec.
- [ ] **Step 3: Implement the codec and ownership rules.** Use Codable binary plists and a deterministic digest helper:

```swift
static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
static func encode(_ archive: BackupArchive) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(archive)
    guard data.count <= limit else { throw BackupError.tooLarge }
    return data
}
```

Define `BackupError: LocalizedError` with invalid, futureVersion, tooLarge, storage,
saveFailed, and recoveryFailed cases. Reads check regular-file type and file size
before loading; decoded sizes use overflow-safe addition. Writes use atomic Data
writes followed by 0600 permissions, and private directories use 0700. Validate
ownership independently of archive-provided profile IDs.

- [ ] **Step 4: Run `swift test --filter BackupArchiveTests`.** Expected: all codec and I/O tests pass.
- [ ] **Step 5: Commit `feat: add versioned backup archive codec`.**

### Task 2: Consistent library capture and semantic preview

**Files:**
- Create: `Sources/Vane/BackupLibrary.swift`
- Create: `Sources/Vane/BackupSQLite.swift`
- Create: `Tests/VaneTests/BackupLibraryTests.swift`
- Modify: `Sources/Vane/Window.swift` (expose a strict session validation/summary adapter alongside the existing tolerant reader).

**Interfaces:**
- Consumes: Task 1 codec, Profile/Space/Session and Easel models.
- Produces: `BackupLibrary(directory: URL, defaults: UserDefaults, domain: String)`, `capture(reason: BackupReason, allowDamaged: Bool = false) throws -> BackupArchive`, `validate(_:) throws -> BackupPreview`, `currentPreferences() throws -> Data`, `applyPreferences(_:) throws`; `BackupPreview` contains per-profile counts and overall totals. `BackupSQLite.snapshot(at:) throws -> Data` and `BackupSQLite.counts(_:) throws -> (bookmarks: Int, history: Int)`.
- Capture takes a flushed snapshot; the runtime flushes pending profile and session saves before invoking it. Library methods operate synchronously at this logical boundary, with immutable bytes handed to detached archive encoding/writing afterwards.

- [ ] **Step 1: Write fixture-based round-trip and preview tests.**

```swift
@MainActor func testClosedProfilesAndEaselIdentitiesSurviveCapture() throws {
    let fixture = try BackupFixture()
    let manager = ProfileManager(directory: fixture.root, sandboxed: true)
    let work = manager.create(name: "Work")
    let board = try EaselStore(profileID: work.id, directory: fixture.root).create(title: "Ideas")
    fixture.defaults.set("https://example.com", forKey: "homepage")
    let archive = try fixture.library.capture(reason: .manual)
    let preview = try fixture.library.validate(archive)
    XCTAssertEqual(preview.profiles.count, 2)
    XCTAssertEqual(preview.profiles.first { $0.id == work.id }?.easels, 1)
    let stored = try XCTUnwrap(archive.files.first { $0.name == EaselStore.file(profileID: work.id, directory: fixture.root).lastPathComponent })
    XCTAssertEqual(try JSONDecoder().decode(EaselStore.Archive.self, from: stored.data).boards.first?.id, board.id)
}
```

Define `BackupFixture` in `Tests/VaneTests/BackupFixture.swift`: unique temporary
root, unique UserDefaults suite, domain string, library computed property, cleanup
that drops the suite and directory. Use explicit XCTest teardown ownership.
Test SQLite with a live connection, disabled autocheckpoint, WAL-only bookmark and
history writes; compare captured counts after opening the snapshot independently.
Test missing optional databases without creating them, empty Spaces, multi-profile
folder/settings bytes, imported filter files and their preference references, archived tabs,
actual PNG image bytes, favourites/pinned/split
and session metadata. Test repeated URLs and two windows sharing tab IDs. Test invalid
profile IDs, orphan ownership, bad session/Space sidecar/Easel schemas and images,
malformed SQLite, symlink source files, and preference filtering of global defaults.

- [ ] **Step 2: Run `swift test --filter BackupLibraryTests`.** Expected: failure because the capture and preview interfaces are absent.
- [ ] **Step 3: Implement strict validation and SQLite capture.** Decode profiles.json into a shared backup-local DTO with profiles and activeID. Require nonempty unique regular profile IDs and valid active selection. Validate every supplied owned file against that profile set. Missing optional files mean empty datasets; malformed present files are errors. Reuse EaselStore.validate and the known sidecar/session schema. Count tab identities using session IDs, space-owned tab occurrences and favourites without dropping intentional duplicates.

```swift
let status = sqlite3_backup_step(backup, -1)
guard status == SQLITE_DONE else { throw BackupError.storage("Could not snapshot bookmarks and history.") }
guard sqlite3_backup_finish(backup) == SQLITE_OK else {
    throw BackupError.storage("Could not finish the database snapshot.")
}
```

Open source databases read-only, finalize/close every handle, bound busy retry time,
validate integrity and required table columns, and read staged snapshot bytes only
after closing its destination connection. Never export -wal/-shm as independent
healthy database payloads. In allowDamaged mode preserve damaged originals with
an explicit archive status and diagnostic; strict validated restores reject damaged
archives. Preference data is a binary plist dictionary from persistentDomain,
excluding transient crash/restore/local bookkeeping keys; preserve arbitrary
app-specific keys and scoped folder bookmarks. Apply by replacing only that domain
and retaining local transient metadata. Check preference synchronization failures.

- [ ] **Step 4: Run `swift test --filter 'BackupArchiveTests|BackupLibraryTests'`.** Expected: all tests pass with no real user data access.
- [ ] **Step 5: Commit `feat: capture complete libraries and preview backups`.**

### Task 3: Durable restore transaction and startup recovery

**Files:**
- Create: `Sources/Vane/BackupRestore.swift`
- Create: `Tests/VaneTests/BackupRestoreTests.swift`
- Modify: `Sources/Vane/main.swift`
- Modify: `Sources/Vane/AppLifecycle.swift` only where needed to prevent shutdown saves after staging.

**Interfaces:**
- Consumes: Tasks 1–2, immutable validated archive and matching BackupLibrary.
- Produces: `BackupRestore(library: BackupLibrary)`, `prepare(_:) throws`, `recoverAtLaunch() throws -> BackupRestore.Result` (`none`, `restored`, `rolledBack`), `cancelPending() throws`, an injectable mutation checkpoint closure for crash/failure tests. Recovery root is `<data-dir>/Recovery`; transaction state is `<root>/Pending`.
- Journal phases: prepared, applying, committed. The applying journal references complete originals and a validated incoming archive; all referenced paths are fixed local names. The original inventory includes owned database WAL companions for byte-faithful rollback of damaged current data; normal restore removes current companions before installing clean snapshots.

- [ ] **Step 1: Write restore and interrupted-launch tests.**

```swift
@MainActor func testRestoreReplacesOwnedFilesAndPreservesUnrelatedFiles() throws {
    let source = try BackupFixture(), target = try BackupFixture()
    _ = ProfileManager(directory: source.root, sandboxed: true)
    _ = ProfileManager(directory: target.root, sandboxed: true)
    try Data("unrelated".utf8).write(to: target.root.appendingPathComponent("keep.txt"))
    target.defaults.set("old", forKey: "homepage")
    source.defaults.set("new", forKey: "homepage")
    let restore = BackupRestore(library: target.library)
    try restore.prepare(source.library.capture(reason: .manual))
    XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
    XCTAssertEqual(target.defaults.string(forKey: "homepage"), "new")
    XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("keep.txt")), Data("unrelated".utf8))
    XCTAssertEqual(try restore.recoverAtLaunch(), .none)
}
```

Add parameterized mutation-checkpoint tests that emulate process interruption (leave
the applying journal in place), create a new restorer, and verify exact original
owned bytes/preferences before any startup adapter opens stores. Include checkpoints
before/after every replacement/removal, preferences, and commit; committed states
finish cleanup without rollback. Test corrupt current profiles/SQLite and WAL,
absent optional incoming files, preservation failure, disk-full staging, journal
corruption, symlink Pending/recovery roots, rollback failure leaving originals intact,
source-file changes after preview, cancellation, and pending transaction conflicts.

- [ ] **Step 2: Run `swift test --filter BackupRestoreTests`.** Expected: missing restore interface failure.
- [ ] **Step 3: Implement the state machine with atomic journals and idempotent rollback.** Keep originals, incoming bytes and journals durable before mutating data. Prepare current recovery point before storing the pending transaction. Startup takes a fresh exact raw-original inventory before recording applying, so rollback restores all current owned paths. Validate restored ownership and lengths independently of the journal. Enforce single-instance ownership with a nonblocking advisory lock, and refuse competing restores. Persist files/preferences before commit; preserve originals if rollback cannot complete.

```swift
switch journal.phase {
case .prepared:
    try validateIncoming()
    try preserveOriginals()
    try writePhase(.applying)
    try installIncoming()
    try writePhase(.committed)
    try cleanPending()
    return .restored
case .applying:
    try restoreOriginals()
    try cleanPending()
    return .rolledBack
case .committed:
    try cleanPending()
    return .restored
}
```

Call launch recovery immediately after Updater.recoverAtLaunch and before FirstLaunch.
On unrecoverable transaction errors show a blocking recovery alert and exit without
normal library initialization. A restored result forces Session.restore once while
preserving Prefs.restoreSession. Keep restart mechanics in Task 5's runtime adapter;
tests of this task never restart the user's app.

- [ ] **Step 4: Run `swift test --filter 'BackupArchiveTests|BackupLibraryTests|BackupRestoreTests|ProfilePersistenceTests|EaselTabTests'` and `scripts/check-webkit-startup.sh`.** Expected: focused tests and startup checks pass.
- [ ] **Step 5: Commit `feat: restore backups with launch-time rollback`.**

### Task 4: Recovery point retention and automatic scheduling

**Files:**
- Create: `Sources/Vane/BackupRecovery.swift`
- Create: `Tests/VaneTests/BackupRecoveryTests.swift`
- Modify: `Sources/Vane/BackupRestore.swift` to use the shared point repository.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `BackupRecovery(library: BackupLibrary)`, `points() throws -> [BackupPoint]`, `save(_:) throws -> BackupPoint`, `automaticPointIfChanged(_:) throws -> BackupPoint?`, `contentDigest(_:) -> String`; BackupPoint has id, date, reason, size, local URL, valid/diagnostic state. `BackupSchedule.isDue(lastAttempt: Date?, now: Date) -> Bool` uses 3600 seconds.

- [ ] **Step 1: Write recovery tests, including first point, unchanged/changed captures and failed retention.**

```swift
@MainActor func testUnchangedContentDoesNotCreateAnotherAutomaticPoint() throws {
    let fixture = try BackupFixture()
    _ = ProfileManager(directory: fixture.root, sandboxed: true)
    let recovery = BackupRecovery(library: fixture.library)
    XCTAssertNotNil(try recovery.automaticPointIfChanged(fixture.library.capture(reason: .automatic)))
    XCTAssertNil(try recovery.automaticPointIfChanged(fixture.library.capture(reason: .automatic)))
    fixture.defaults.set("changed", forKey: "homepage")
    XCTAssertNotNil(try recovery.automaticPointIfChanged(fixture.library.capture(reason: .automatic)))
    XCTAssertEqual(try recovery.points().count, 2)
}
```

Test twelve completed points retain exactly ten, tied dates, damaged pre-restore
points, failed writes retaining the last good point, pruning failure reporting,
corrupt point listing, two independent data directories, hashing independent of
archive dates/reasons/order, and 3599/3600-second scheduling boundaries. Database
content fingerprints must ignore snapshot-specific volatile SQLite header fields
without ignoring actual bookmark/history changes.

- [ ] **Step 2: Run `swift test --filter BackupRecoveryTests`.** Expected: missing repository/schedule failure.
- [ ] **Step 3: Implement repository and schedule policy.** Store atomic archives in
Recovery/Points with UUID filenames. Validate a new point before pruning; sort by
creation date and UUID. Derive semantic content fingerprint from ordered owned
payloads and normalized preference dictionaries, including normalized SQLite content.
Use the same repository for mandatory beforeRestore points. Do not silently swallow
listing/writing/pruning errors; expose last successful point and diagnostics.

```swift
static func isDue(lastAttempt: Date?, now: Date) -> Bool {
    guard let lastAttempt else { return true }
    return now.timeIntervalSince(lastAttempt) >= 3600
}
```

- [ ] **Step 4: Run `swift test --filter 'BackupArchiveTests|BackupLibraryTests|BackupRestoreTests|BackupRecoveryTests'`.** Expected: all backup tests pass.
- [ ] **Step 5: Commit `feat: retain automatic local recovery points`.**

### Task 5: Settings, preview, restart and delivery

**Files:**
- Create: `Sources/Vane/BackupController.swift`
- Create: `Sources/Vane/BackupSettings.swift`
- Create: `Tests/VaneTests/BackupControllerTests.swift`
- Modify: `Sources/Vane/SettingsWindow.swift`
- Modify: `Sources/Vane/main.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1–4; SettingsSection/SettingsCard/SettingsRow/Footnote and Motion.reduced.
- Produces: `@MainActor BackupController: ObservableObject` with shared runtime,
busy/progress/status/points/preview/error published state; `export(to:) async`,
`previewRestore(from:) async`, `restorePreview() async`, `retryRecovery() async`,
`begin()`; injected flush/capture/restart hooks for tests. `BackupSettings: View`
renders the section and `BackupPreviewView: View` renders confirmation.

- [ ] **Step 1: Write controller integration tests.** Inject scratch library and
restart closure, then assert save failure prevents export, cancel prevents staging,
busy state blocks overlapping commands, external backup mutation cannot affect
preview bytes, recovery scheduling pauses during restore, errors retain last
successful status, and restart failure clears pending restore without changing the
library. Test flush failures individually for profiles and Session.save.

```swift
@MainActor func testFlushFailureDoesNotExportStaleData() async throws {
    let fixture = try BackupFixture()
    let controller = BackupController(library: fixture.library,
        flush: { false }, restart: { throw BackupError.saveFailed })
    let output = fixture.root.appendingPathComponent("export.vanebackup")
    await controller.export(to: output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertNotNil(controller.error)
    XCTAssertFalse(controller.busy)
}
```

- [ ] **Step 2: Run `swift test --filter BackupControllerTests`.** Expected: missing controller failure.
- [ ] **Step 3: Implement controller and views.** Construct runtime defaults-domain
identity from VANE_DATA_DIR suite or actual app bundle identifier; never fall back
to an unrelated global domain. Flush synchronously before capturing; archive encode,
decode and output I/O run detached on immutable Sendable data. Route validation and
point storage through the services already tested. Timer starts after launch and
checks hourly; prevent overlap. File panels only start jobs after OK. Sheet shows
per-profile totals, current totals, date/app version, exclusions, restart and
replacement copy, and Cancel/Restore and Restart. Use Motion.list for preview/status
changes. Render retry and damaged-point diagnostics accessibly.

```swift
SettingsSection("Backup and Restore") {
    BackupSettings(controller: .shared)
}
```

Insert above Reset Vane in AdvancedPane. Restart a bundled app by its actual bundle
URL, wait for the tracked parent process to exit, and forward VANE_DATA_DIR. Require
successful helper launch before exit(0), bypassing normal session-save callbacks
only for the prepared restore. Preserve the user's quit preferences. Bare executable
restart must use the executable URL and the same environment. Add README coverage
for included data, unencrypted exports, preview/restart, hourly ten-point retention,
limits, excluded credentials/site storage/external files, and backup test commands.

- [ ] **Step 4: Run `swift build -c debug`, `swift test --filter 'Backup.*Tests|ProfilePersistenceTests|EaselTabTests|EaselTests|SpaceDeletionTests|HistoryPersistenceTests'`, `./.build/debug/vane selfcheck --pure`, `scripts/check-webkit-startup.sh`, and `git diff --check`.** Expected: build and all relevant checks pass. Broaden tests only for failures or unresolved risks.
- [ ] **Step 5: Assemble a task-owned app with `./make-app.sh debug`; launch it with an isolated VANE_DATA_DIR and track bundle path, PID and start time.** Populate two regular profiles, bookmarks, tabs and an Easel image, export, mutate, inspect preview, cancel once, then restore and relaunch. Verify restored settings, tab/board references, recovery list, and reduced motion. Record actual results and any blocked checks; do not count a blocked live check as passed.
- [ ] **Step 6: Commit `feat: add backup and restore settings`.** Push codex/backup-restore and open a PR with scope and validation; attach it to the chat.
- [ ] **Step 7: Obtain independent review of the PR's current head through a fresh reviewer subagent.** Address actionable findings, add regression coverage, push, and repeat review and relevant validation until there are no unresolved actionable findings. The project workflow overrides any skill's single-review limitation.
- [ ] **Step 8: Confirm latest head review, required CI checks and approvals, and mergeability; squash-merge and verify merged status and squash commit.** Required unavailable/pending checks are blockers. Stop every task-owned test app, validate PID/executable/start time before signals, and verify exit. Preserve the user's primary checkout and regular Vane processes. Report PR, squash commit, checks, and any material limitation.
