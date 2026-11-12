# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize every approved portable Vane category through opt-in iCloud controls, excluding downloaded files.

**Architecture:** Keep local stores authoritative for local durability. Category adapters export/import portable entities; a durable, causal merge journal reconciles them through CloudKit, while passwords/API keys use synchronizable Keychain items. Each Mac owns its switches and tab lists; account/category generations reject stale asynchronous work.

**Tech Stack:** Swift 6, macOS 26+, SwiftUI/AppKit, SQLite, CloudKit CKSyncEngine, Security Keychain, XCTest. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-10-icloud-sync-design.md`

## Global Constraints

- Private browsing never enters sync.
- There is no downloaded-file sync option, including under Select All.
- Master sync starts off. Both sending and receiving require that Mac's category switch.
- Passwords and AI keys use synchronizable, correctly access-group-scoped Keychain items, independently of CloudKit.
- Incoming executable content does not inherit this Mac's execution permission.
- Existing libraries merge; never replace database/session files with a remote snapshot.
- No release work or claims of two-Mac readiness without the spec's signed-build checks.

## Review Focus

- A disabled parent category must not leak its names/settings through enabled child entities; test child-only placeholder handling in Task 3.
- A stale read/import callback must not re-enable a category or cross Apple Accounts; test generation revocation in Tasks 1 and 6.
- Download metadata must never resolve arbitrary local paths or transfer bytes; test remote history without local actions in Task 3.
- Restored/imported data must not look like wholesale deletion or bypass executable-content consent; test baseline reconciliation and inactive scripts/extensions in Tasks 1 and 4.
- Changing the Apple Account while the app was quit must quarantine pending records and secret migrations; test account transition before outgoing admission in Tasks 2 and 5.

## File map and shared contracts

New files under `Sources/Vane/` use the `ICloud` prefix, following the existing flat layout:

- `ICloudModel.swift`: category metadata, portable entities, causal record representation, transport protocol.
- `ICloudJournal.swift`: worker-confined atomic durable state, snapshot diffing and deterministic record merge.
- `ICloudTransport.swift`: entitlement-gated CKSyncEngine, account identity and category-zone transport.
- `ICloudLibraryAdapter.swift`: profiles, Spaces, favourites, pins, folders, templates, bookmarks/history and per-device browsing/download lists.
- `ICloudContentAdapter.swift`: Easels, reading articles/assets, Boosts and blocker content.
- `ICloudPreferencesAdapter.swift`: explicit allowlists and extension installation/sync-data integration.
- `ICloudSecrets.swift`: synchronizable Keychain mirror with conflict-preserving migration.
- `ICloudController.swift`: lifecycle, switches, capture/apply barriers, reset and recovery point.
- `ICloudSettings.swift`: setup/category controls, status, other-Mac lists and reset confirmation.

Existing integration files: `SettingsWindow.swift`, `main.swift`, `AppLifecycle.swift`, local persistence owners as needed, `make-app.sh`, and signing-specific entitlements. No broad refactor of existing persistence.

Shared Swift interfaces, to be implemented in Task 1 before independent adapters:

```swift
enum ICloudCategory: String, Codable, CaseIterable, Sendable // all categories in the spec
struct ICloudItem: Codable, Equatable, Sendable {
    var category: ICloudCategory
    var id: String
    var profileID: UUID?
    var parentID: String?
    var fields: [String: Data]
}
@MainActor protocol ICloudAdapter {
    var categories: Set<ICloudCategory> { get }
    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem]
    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws
}
```

Adapters receive only admitted category sets and never consume secrets. Each entity uses named serialized fields for independent merge. An empty capture is accepted as absence only after the entire category succeeds. Failed/partial capture never causes inferred deletion. IDs are portable and profile-qualified; cloud record names hash them. Asset fields carry immutable digest-addressed content, not arbitrary file URLs. 256 KiB inline fields, 32 MiB per saved asset, 256 MiB per cycle, 200 mutations per transport batch; exceeding bounds produces a visible error and retains pending work. Existing tighter bounds take precedence. Password/API-key categories are never encoded in CloudKit items.

### Task 1: Category model and durable causal merge journal

**Files:** Create `ICloudModel.swift`, `ICloudJournal.swift`; tests `Tests/VaneTests/ICloudJournalTests.swift`.

**Interfaces:** Produces the shared contracts above; `ICloudJournal(directory:deviceID:)`, `capture(_:enabled:)`, `merge(_:)`, `pending(enabled:)`, `acknowledge(_:)`, `checkpoint()`, and per-account/category generation state. Concrete actor signatures are defined with implementation tests and recorded here before consumers are dispatched.

- [ ] Write tests first: master/category defaults exclude sensitive categories; per-field concurrent edits converge in either order; deletion beats concurrent edits; unknown/disabled snapshots do not delete; failed disk save does not acknowledge; reload preserves pending edits, tombstones, baselines and device identity; changed account quarantines pending data.
- [ ] Run `swift test --filter ICloudJournalTests`; confirm new symbols fail before implementing them.
- [ ] Implement stable vector-clock field merges, deletion markers, category baselines and atomic worker-owned journal persistence. Preserve a conflicting Easel as a second stable board identity. Keep no URL/title in record identifiers or logs.
- [ ] Run the focused tests; expect all pass, then commit model/journal/tests.

### Task 2: CloudKit transport and provisioned-build gating

**Files:** Create `ICloudTransport.swift`; tests `Tests/VaneTests/ICloudTransportTests.swift`; modify `make-app.sh`; add distribution-specific entitlement template and provisioning documentation without altering release behavior by default.

**Interfaces:** Consumes Task 1 records. Produces an injected transport accepted by the controller: account identity/status, explicit fetch/send, serialized engine-state callback, acknowledged records, received records, and category namespace reset. Production uses CKSyncEngine and private category zones. No initializer contacts CloudKit before entitlement checks.

- [ ] Test missing entitlements, unknown schemas, partial acknowledgement, retries, account mismatch and a reset observed before queued sends; use injected transport/backend, no real Apple Account.
- [ ] Run `swift test --filter ICloudTransportTests` and observe red.
- [ ] Implement fetch-before-send control-epoch admission, encrypted fields, assets with immutable staging, server-conflict merge and durable engine-state events. A reset advances namespace before zone removal so stale devices cannot repopulate the active namespace.
- [ ] Generate restricted entitlements only with an explicitly supplied validated provisioning profile; ad-hoc builds remain runnable and unavailable for sync. Explain Apple container/schema setup.
- [ ] Run focused tests plus `bash -n make-app.sh`; expect pass, then commit.

### Task 3: Organized library and device-owned browsing lists

**Files:** Create `ICloudLibraryAdapter.swift`; add narrow methods to `Profiles.swift`, `Store.swift`, `Downloads.swift`, `Folders.swift`, session owners only as required; tests `Tests/VaneTests/ICloudLibraryAdapterTests.swift`.

**Interfaces:** Implements `ICloudAdapter`, initialized with injected directory/defaults/device identity and local owners. Covers `.profiles`, `.spaces`, `.favourites`, `.pinnedTabs`, `.sidebarFolders`, `.bookmarks`, `.history`, `.openTabs`, `.recentlyClosedTabs`, `.spaceTemplates`, `.downloadHistory`.

- [ ] Test two local profiles with equal names, fixed default profile merge, bookmark URL deduplication, independent field changes, folder hierarchy/protection, disabled-parent placeholders and profile deletion across child switches.
- [ ] Test device-labelled tab lists never mutate current navigation, and completed-download history strips paths/grants/resume data and never offers remote file actions.
- [ ] Run `swift test --filter ICloudLibraryAdapterTests` and observe red.
- [ ] Export committed data through existing persistence barriers and stable sync IDs. Apply in dependency order, through local owners, honoring save failure and isolation. Extend local stable bookmark/history identity without reusing another profile's SQLite row ID.
- [ ] Keep other-device tabs/downloads in a separate local sync view model; opening one creates a normal local tab. Clear-history deletion uses durable observed identities, not a fresh empty export.
- [ ] Run focused tests and relevant profile/history/bookmark/download regressions; expect pass, then commit.

### Task 4: Saved content, settings, extensions and content assets

**Files:** Create `ICloudContentAdapter.swift`, `ICloudPreferencesAdapter.swift`; narrowly extend reading/Easel/extension owners if needed; tests `ICloudContentAdapterTests.swift`, `ICloudPreferencesAdapterTests.swift`.

**Interfaces:** Both implement `ICloudAdapter`. Content categories: `.easels`, `.readingQueue`, `.offlineArticles`, `.boosts`, `.contentBlocking`. Preference categories: `.appearance`, `.readerPreferences`, `.search`, `.keyboardShortcuts`, `.portablePreferences`, `.siteSettings`, `.extensions`, `.extensionSyncData`.

- [ ] Write tests for saved text/images, missing/oversize/damaged assets, metadata-only reading queue, per-board concurrent conflict preservation, independent allowlisted settings and rejects of permissions/paths/Keychain references.
- [ ] Test Boost scripts arrive disabled, extension packages arrive staged/unapproved, Safari installation requires local host app, only storage.sync is portable, and protected/local-only extension data never exports.
- [ ] Run both focused test classes and observe red.
- [ ] Implement immutable validated assets, existing reading/Easel writer barriers, explicit preference key lists, and verified extension transfer via local owners. Do not replace UserDefaults domains or copy extension storage.local/session.
- [ ] Run focused tests and related saved-content/extension regressions; expect pass, then commit.

### Task 5: Optional iCloud Keychain passwords and AI keys

**Files:** Create `ICloudSecrets.swift`; modify `Passwords.swift`, `AIKeys.swift`, their settings copy and tests `ICloudSecretsTests.swift`.

**Interfaces:** `ICloudSecrets` is an independently injected Keychain bridge; category controls enable passwords/API keys separately. It participates in account-generation revocation and reports actionable conflict/status information to the controller. Secret values never pass through `ICloudItem` or journal serialization.

- [ ] Test the query construction/access groups and namespace isolation, unavailable/locked Keychain, cloud conflict, save-readback failure, disable preserves originals, explicit removal and account change between migration read/write.
- [ ] Run `swift test --filter ICloudSecretsTests` and observe red.
- [ ] Mirror Vane-owned items into synchronizable data-protection Keychain records only after opt-in. Refresh remote items into local originals via the existing serial secret lanes; preserve conflicts and avoid any ThisDeviceOnly attribute on synchronizable records.
- [ ] Show that disabling stops Vane's cloud interactions but cannot pause Apple's existing Keychain transport. Do not synchronize rotating GitHub OAuth pairs.
- [ ] Run focused tests plus existing password-profile isolation tests; expect pass, then commit.

### Task 6: Controller, settings, other-Mac UI and lifecycle

**Files:** Create `ICloudController.swift`, `ICloudSettings.swift`; modify `SettingsWindow.swift`, `main.swift`, `AppLifecycle.swift`, backup-local preference exclusion; tests `ICloudControllerTests.swift`.

**Interfaces:** `@MainActor ICloudController: ObservableObject` owns master/category preferences, account state, status/errors, last success and other-device entries. `ICloudSettings` observes `.shared`. `start()`, `syncNow()`, `setEnabled(_:for:)`, `setMasterEnabled(_:)`, `removeCloudData(_:)`, `flushAndStop()` supply lifecycle/UI entry points.

- [ ] Test no upload before setup/recovery point, generation revoke during capture/fetch/apply, no success on partial saves, account-switch quarantine, reset pauses other Macs, disabled category reconciliation, backup/restore exclusion of local switches and drain on quit.
- [ ] Run `swift test --filter ICloudControllerTests` and observe red.
- [ ] Implement sync admission with recoverable before-first-merge checkpoint, serialized capture/apply, disk-error propagation and retry. Start only after app recovery/bootstrap; stop before restore/termination and never capture private state.
- [ ] Add grouped individual toggles, Select All review, sensitive defaults, Sync Now, status/error recovery, account-change consent, Other Macs open/open-all, category-aware reset confirmation and Keychain caveats. Follow existing settings cards/rows and motion policies.
- [ ] Run focused controller tests and relevant bootstrap/backup regressions; expect pass, then commit.

### Task 7: Whole-feature validation, independent review and integration

**Files:** Update `README.md`, `PRIVACY.md`, `docs/DATA-AND-PRIVACY.md`, `docs/DEVELOPMENT.md`, website privacy/feature claims as applicable; record evidence alongside this plan.

- [ ] Run `swift build -c release`, the pure selfcheck, full local XCTest suite appropriate to native readiness, and `git diff --check`; investigate original failures rather than hide them with retries.
- [x] Run signed, isolated one-Mac service and two-journal transport tests against Development and Production, recording exact source and cleanup receipts. Provisioning/schema setup and these checks passed. User decision on 11 November 2026: missing second-Mac hardware is not a merge or release gate. Cross-Mac category/lifecycle and Keychain propagation checks remain explicitly unverified follow-up coverage.
- [ ] Obtain independent current-diff review, fix findings and repeat relevant validation/review.
- [ ] Open/link a PR with exact scope, evidence and unresolved live-service dependencies. Observe all required PR and main CI before squash-merge. Do not bypass blockers or perform release operations.
- [ ] Verify the merge and clean up only task-owned test apps/worktrees whose work is preserved.
