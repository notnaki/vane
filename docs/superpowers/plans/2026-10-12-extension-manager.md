# Extension Manager Implementation Plan

> **For agentic workers:** Use test-driven implementation for behavior changes and independent final PR review. The user authorized continuous execution and superseded further design/plan approval gates.

**Goal:** A complete local extension manager with safer accepted-code updates and useful public WebKit integration.

**Architecture:** Extend ExtensionHost with profile-owned immutable code revisions and cached metadata. Keep its legacy installation keys and WebKit UUIDs. A native manager consumes Entry snapshots; runtime changes remain scoped to existing controller/adapters.

**Tech Stack:** Swift, SwiftUI, AppKit, public WKWebExtension APIs; no new external service.

**Spec:** docs/superpowers/specs/2026-10-12-extension-manager-design.md

## Global Constraints

- macOS 26 remains the minimum; no Vane service or account.
- Preserve installed extension UUIDs, origins, controller identifiers, required approvals, disabled state, pins, and storage.
- Private profiles cannot install extensions.
- Review always precedes context activation; source edits apply through explicit updates after migration.
- Respect Reduce Motion and Battery Saver; preserve unrelated local work.
- Required CI, independent current-head PR review, fixes and squash-merge; clean up owned test apps.

## Review Focus

- Removal/profile deletion during nested consent or background await must invalidate staged candidates and prevent resurrection.
- A source folder changing during review must not alter the reviewed staged bytes.
- Failed persistence or activation must retain accepted code and approval without a new storage identity.
- A missing source must not stop a managed installed revision; missing legacy code stays actionable.
- Keyboard commands and menus must not cross profiles or bypass private/locked/modal constraints.

### Task 1: Accepted revision store and host migration

Files: new ExtensionCodeStore.swift; Extensions.swift install/load/persistence/Entry sections; Profiles.swift cleanup; ExtensionConsent.swift review copy; ExtensionManagedCodeTests.swift and existing extension regressions.

- [ ] Add real folder/host tests that fail for source mutation leaking into accepted code, broken/declined updates discarding working code, changed-source consent races, disabled update enabling code, and identity/storage loss.
- [ ] Run `swift test --filter ExtensionManagedCodeTests`, confirm intended failures.
- [ ] Implement bounded no-symlink staging, profile installation records, accepted revision persistence, legacy migration, source repair and rollback, preserving old UUID/origin and consent keys. Stage before WebKit parsing, review staged bytes, never execute changed source directly after adoption.
- [ ] Run all focused extension tests; update assertions only where explicitly changed accepted-code behavior replaces old folder semantics.

### Task 2: Native manager

Files: ExtensionManagement.swift; new ExtensionManagerModel.swift; Actions.swift command-palette entry; ExtensionManagerModelTests.swift.

Interfaces: ExtensionHost.Entry exposes path/name/context/status/failure/busy plus version, summary, icon, enabled, managed, sourceAvailable, requiredAccess, optionalAccess, compatibility. Host actions: setEnabled(_:for:), chooseUpdate(for:), retry(_:), diagnostic(for:), revokeRuntimeAccess(_:), install(folder:), togglePin(_:), remove(folder:).

- [ ] Add filter/search behavior tests for case/diacritic matching, attention counts, inactive metadata and profile-specific command action.
- [ ] Implement native adaptive list/detail window, profile header, search and counted filters, enable/pin actions, empty/private states, folder drop, review/recovery feedback, permission sections with expiration and revocation, confirmation removal and sanitized copy.
- [ ] Build and run focused manager tests; visually verify wide/narrow/light/dark and keyboard/VoiceOver labels.

### Task 3: Runtime integration

Files: Extensions.swift runtime sections only; new ExtensionCommands.swift as useful; main.swift key monitor; ExtensionDiagnostics.swift unsupported declarations; runtime/lifecycle tests.

- [ ] Add tests for command routing, disabled/stale contexts, profile/modal/text-entry guards, moved/selected/closed tabs and menu API exposure.
- [ ] Implement command dispatch after browser commands, expose commands/collisions; inspect WebKit page-menu integration and enable only verified capabilities; notify movement/selection/window close correctly without stale adapters.
- [ ] Run runtime/lifecycle/permissions regressions and verify real popup/options/menu/command workflows in assembled app.

### Task 4: Compatibility and delivery

Files: docs/INTEGRATIONS.md, docs/EXTENSION-VALIDATION.md; supporting test fixtures where needed; privacy/backup guides if managed code changes exclusions.

- [ ] Investigate ZIP import and native messaging with public APIs; document exact decision and native-host requirements without adding host execution.
- [ ] Obtain representative upstream content utility, blocker, and password-manager packages where feasible. Record exact versions/provenance and successes/failures without real user credentials.
- [ ] Run focused tests, pure selfcheck, assemble debug app and verify manager/runtime workflows in isolated VANE_DATA_DIR. Record every owned app PID, executable and process start time.
- [ ] Open PR, independently review its current diff, fix actionable findings, confirm current-head CI/review/mergeability, squash-merge, verify merge commit, clean owned test app instances and report limitations.
