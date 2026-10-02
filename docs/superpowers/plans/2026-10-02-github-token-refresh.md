# GitHub OAuth Renewal Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Live Folders connected when GitHub's eight-hour OAuth access token expires.

**Architecture:** Persist the complete OAuth grant as one versioned Keychain value, retaining compatibility with existing raw tokens. A per-profile renewal coordinator and file lock serialize refresh-token rotation, re-read credentials after acquiring the lock, and save the new pair before using it. Live Folders renews before expiry and retries a rejected token once; failures retain credentials and tabs.

**Tech Stack:** Swift 6, Foundation URLSession, Security, Darwin flock, XCTest.

**Spec:** The user's request to test/fix recurring GitHub Live Folder sign-outs, plus confirmed expiry configuration at https://github.com/settings/applications/3845549/beta.

## Global Constraints

- Preserve unrelated local changes; use codex/github-token-refresh in an isolated worktree.
- Secrets stay in the existing profile/instance-scoped Keychain; log no tokens or response bodies.
- Preserve personal access tokens and non-expiring OAuth tokens.
- Merge only after independent review of the latest head and passing required checks.
- Do not launch or terminate another task's test app.

## Review Focus

- Expiring grants must keep both tokens across relaunch.
- Concurrent folders/processes must rotate once and reuse the saved replacement.
- Sign-out/replacement while a renewal is pending must not resurrect old credentials.
- Network and Keychain failures must retain the old pair and permit retry.
- Malformed OAuth replies, expired refresh tokens, and missing release secrets must fail without saving incomplete credentials.

### Task 1: Grant persistence and renewal

**Files:** Create Sources/Vane/GitHubCredential.swift and Tests/VaneTests/GitHubRenewalTests.swift; modify Sources/Vane/LiveFolders.swift, README.md, and scripts/check-live-credential-persistence.py.

- [x] Add failing XCTest coverage for complete grant decoding and persistence, legacy tokens, due-time decisions, form escaping, and serialized renewal with an injected transport and storage fixture. Run `swift test --filter GitHubRenewalTests` and confirm the missing implementation fails.
- [x] Implement `GitHubCredential` as a Codable value with accessToken, refreshToken, expiresAt, and refreshExpiresAt; version its stored string and retain raw-token decoding.
- [x] Implement refresh request construction and decoding; require the refresh token whenever an expiry is returned.
- [x] Implement `GitHubTokenRenewal` using a per-profile flock and injected read/write/transport/secret closures. Recheck the persisted value before saving. Return offline/unauthorised failures without deleting credentials.
- [x] Integrate grant saving in OAuth exchange, grant decoding in LiveCredentialCache, and renewal before fetch plus a single retry on 401. Serialize explicit saves/removals with the same lock.
- [x] Cover simultaneous renewal, relaunch, stale responses, sign-out/replacement, lock contention, offline retry, failed persistence, and rejection in regression tests.
- [x] Extend the disposable fresh-process Keychain script to verify a complete versioned grant, then document automatic renewal and the one reconnect needed for previously discarded refresh tokens.
- [x] Run `swift build -c debug`, `swift test`, isolated `vane selfcheck --pure`, credential persistence check, `./make-app.sh debug`; confirm the CI DMG packaging check passes. Local build, 128 tests, pure selfcheck, Keychain persistence, and app packaging passed.
- [ ] Commit only task changes, open PR, obtain independent review, resolve findings, verify current head/CI/mergeability, squash-merge, and clean up any owned test processes.
