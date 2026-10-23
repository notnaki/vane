# Update Security Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or native execution with independent review. Track steps below.

**Goal:** Complete the remaining updater and credential security hardening before release.

**Architecture:** Stream and meter transport and extraction before writing bytes. Move all application transaction mutations into authenticated XPC, carrying kernel-derived browser ownership into the replacement engine. Separate native token storage and remove stale certificate outcomes.

**Tech Stack:** Swift 6, Foundation URLSession, a narrow ZIP reader with system zlib, Darwin filesystem/process APIs, Security, NSXPCConnection.

**Spec:** `docs/superpowers/specs/2026-10-23-update-security.md`

## Global Constraints

- macOS 26 remains the minimum; preserve App Sandbox, Hardened Runtime, signature, Gatekeeper, version and architecture checks.
- No publishing a public release; preserve unrelated changes and task-instance isolation.
- Limits: 200 MiB download; 1 GiB expanded; 512 MiB/file; 20,000 entries; 1,024 path bytes; 32 components; 120 seconds extraction.
- Every meaningful security fix gets a reproducing regression; final CI and independent review precede squash merge.

## Review Focus

- Actual ditto release ZIP metadata and executable permissions must remain usable and signatures intact (Task 1).
- Missing lengths, redirect chains and interrupted bodies must not escape streaming limits or leave files (Task 1).
- Old running executable moved by a swap cannot approve the replacement, including orphan cleanup (Task 2).
- Rollback to an older helper must still reopen the restored application, preserving isolated data (Task 2).
- Keychain failures during migration must preserve the only token without exposing it to autofill (Task 3).

### Task 1: Bound update transport and extraction

**Files:** `Sources/Vane/UpdateDownload.swift`, `Sources/Vane/UpdateArchive.swift`, archive C API/target if needed, `Package.swift`, download/extraction regions of `Sources/Vane/Updater.swift`, `Tests/UpdaterTransport/main.swift`, `scripts/test-updater-transport.py`, new archive fixtures/script, CI.

**Interfaces:** `UpdateDownload` accepts a trusted-URL predicate, byte cap, destination, progress and completion; `UpdateArchive.extract(zip:to:limits:) throws` consumes a private destination. Updater supplies production policy; tests inject loopback and small limits only.

- [ ] Write real-production-path transport and archive tests for normal input, dishonest lengths, size/entry/path budgets, deadlines, malformed/truncated ZIP, links/collisions and failed-output cleanup.
- [ ] Run tests, observe failures before implementation.
- [ ] Implement bounded transport and system ZIP streaming extraction, checking emitted bytes before writes; integrate with Updater and CI. Keep existing invalid-ZIP transient behavior.
- [ ] Run `python3 scripts/test-updater-transport.py` and `python3 scripts/test-updater-archive.py`; expect all PASS. Check a real ditto fixture and signed bundle signature after extraction.
- [ ] Commit only Task 1 files.

### Task 2: Move recovery and health into authenticated XPC

**Files:** `Sources/Vane/BundleReplacement.swift`, `Sources/Vane/UpdateInstaller.swift`, `Sources/UpdateInstaller/InstallerService.swift`, recovery/relaunch regions of `Sources/Vane/Updater.swift`, `Vane.entitlements`, `make-app.sh`, native/XPC recovery fixtures and their scripts, default-browser packaging fixture.

**Interfaces:** Kernel-derived caller context contains PID/start and an ownership revalidation closure. Engine `beginLaunch` and `markHealthy` accept that context; XPC methods derive it from their own connection, never request arguments. Client decodes explicit launch results, fails closed on unavailable pending recovery. `scheduleRelaunch` supports ordinary and isolated launches.

- [ ] Add regressions for recorded browser identity, wrong/stale caller, mismatched executable, concurrent owner, orphan cleanup and health ownership. Add entitlement assertions and signed sandbox denial probes for both Applications directories.
- [ ] Run reproductions before implementation; expect unsafe/unavailable behavior to fail.
- [ ] Implement per-connection authenticated handler and ownership checks inside transaction lock. Move browser mutations to XPC; preserve no-record ad-hoc launch and post-rollback compatibility. Route normal supervised restart through XPC.
- [ ] Replace Applications write exceptions with read-only keys; update packaging tests and configure native candidates with fixture helpers.
- [ ] Run recovery/relaunch, packaging and signed XPC/native fixture tests; expect all PASS and verified task-process cleanup.
- [ ] Commit only Task 2 files.

### Task 3: Separate integration credentials and refresh trust evaluation

**Files:** `Sources/Vane/CertificateTrust.swift`, native token storage, `Sources/Vane/LiveFolders.swift`, `Sources/Vane/Passwords.swift`, affected focused tests.

**Interfaces:** Keep `Passwords.CredentialRead` behavior for existing integration consumers; generic-password service/account keys scope tokens to profile and isolated data directory. Legacy migration deletes only owned persistent references after durable replacement, and web-password enumeration excludes legacy token origin.

- [ ] Add trust-date/same-leaf regressions and token class/isolation/migration/deletion/locked-Keychain tests; observe RED.
- [ ] Remove leaf-only outcome reuse; switch integrations to generic-password storage with safe migration and deletion hooks.
- [ ] Run focused certificate, password, Live Folders and renewal tests; expect PASS.
- [ ] Commit only Task 3 files.

### Task 4: Release evidence, review and integration

**Files:** `docs/SECURITY-AUDIT.md`, `docs/RELEASING.md`, relevant CI/docs.

**Interfaces:** Consume the final implementations and test evidence, without implying an untested signed release candidate is approved.

- [ ] Update audit and release procedures with actual guarantees, limits and remaining candidate-specific checks.
- [ ] Build and run focused/full checks as justified; inspect every failure and document environmental limits honestly.
- [ ] Create PR, attach to this task, obtain independent review of current head; fix findings and repeat relevant tests/review.
- [ ] Confirm final head reviewed, CI passed, approvals and mergeability, then squash merge. Verify merge and stop all tracked test instances.

## Validation findings addressed

The signed rollback fixtures exposed an older release's fresh-welcome resource failure
and a database-before-crash false pass. Added `AppResources` to resolve the actual packaged
bundle lazily, with relocated flat-bundle regression tests. Upgrade fixtures preserve
completed onboarding/default-browser consent, require the same browser identity to remain
alive, and wait for actual healthy transaction cleanup under startup load. An initial
notification-loss hypothesis was not established; production health timing is unchanged.
