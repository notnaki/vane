# Chrome Web Store Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install and update verified Chrome Web Store extensions through Vane's existing WebKit runtime.

**Architecture:** A store source value validates IDs and constructs Google requests; a CRX3 verifier returns authenticated ZIP bytes; the existing bounded archive reader extracts private staging. ExtensionHost commits store sources through its transactional managed-code path. An isolated store-page script and a manager dialog call that host.

**Tech Stack:** Swift, WebKit, Security, CryptoKit, Foundation, existing zlib ZIP reader.

**Spec:** ../specs/2026-10-28-chrome-web-store-design.md

## Global Constraints

- macOS 26 remains the minimum.
- No native host execution or private extension support.
- Preserve local changes and existing extension identities.
- Require ID-bound developer and pinned production Google publisher signatures before extraction.

## Review Focus

- Forged store URLs/messages cannot install a different ID or reach arbitrary download hosts.
- Oversized/corrupt packages cannot allocate without bounds or write outside staging.
- Removing/disabling an extension during download cannot resurrect it.
- Updating disabled installations retains disabled state and runtime identity.
- Permission increases retain the accepted version until explicitly approved.

### Task 1: Authenticated package pipeline

Files: ChromeWebStore.swift, ChromeExtensionPackage.swift, Tests/VaneTests/ChromeWebStoreTests.swift.

- [x] Write ID/URL, generated-signature tamper/mismatch, and extraction tests. Run them to observe missing support.
- [x] Implement strict source parsing, CRX3 protobuf/SPKI verification, bounded ephemeral download, and extraction through UpdateArchive.
- [x] Run focused package tests and validate a freshly downloaded real store package.

### Task 2: Managed store lifecycle

Files: Extensions.swift, ExtensionCodeStore.swift, Tests/VaneTests/ChromeExtensionLifecycleTests.swift.

- [x] Test store installation, runtime ID, update permission gating, disabled update, rollback and cancellation using signed fixtures.
- [x] Extend managed sources and the existing candidate transaction; add daily checks and explicit store refresh.
- [x] Run extension lifecycle/consent/code store regressions.

### Task 3: Store installation UI

Files: ChromeWebStorePage.swift, Engine.swift, ExtensionManagement.swift, tests and integration/privacy docs.

- [x] Test origin/frame/profile validation and store page DOM interaction.
- [x] Add Add to Vane on store pages and store-link/ID installation in the manager, with motion policy and clear progress/errors.
- [x] Build the assembled app; validate real package installation and store-page interaction in isolated fixtures.
- [ ] Document behavior/limits/network requests, review current diff independently, fix findings, pass required CI and squash-merge.

## Execution record

- User selected Yab's documented approach and authorized implementation. Implement inline; independently review the complete PR as required by AGENTS.md.
- Reuse UpdateArchive instead of adding another ZIP implementation.

- Package tests verified a freshly downloaded Dark Reader 4.9.134 CRX, including real RSA/Google publisher proofs. The live network/runtime fixture passed.
- 178 extension-focused regressions passed (14 platform/opt-in skips); ZIP adversarial fixtures passed. The signed debug app installed Dark Reader through the live store button and showed its store source/update control.
- Reinstall regression first exposed old storage under the stable Chrome ID; reusing the existing serialized purge fixed it.

- Independent review of 97f125a found three P2 recovery issues. Regression tests reproduced each; fixes preserve store source/identity when metadata is unreadable, permit reviewed equivalent-version repairs of damaged accepted code, and clear resolved attention without replacing healthy code.
- After fixes, 152 focused extension tests passed (14 platform/opt-in skips), including live store download and package verification; fixture retirement passed. The signed debug app rebuilt successfully.
- A broader name-filter run also included unrelated media tests and had one PiP video pause assertion failure; its isolated rerun passed after the UI test app was closed. No media code changed.
- Both tracked Vane UI test process IDs (90337, 91590) are confirmed exited; the second needed a specific TERM after computer-use quit was blocked by changing foreground state. The regular user app was not targeted.
