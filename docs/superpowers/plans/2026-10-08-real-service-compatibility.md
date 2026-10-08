# macOS 27 compatibility execution plan

**Goal:** Extend scoped compatibility evidence, fix reproduced evidence defects,
and leave resource-dependent service checks explicitly unverified.

**Spec:** The user's compatibility request and `docs/REAL-SITE-COMPATIBILITY.md`.
**Architecture:** Use production Tab/WebKit with isolated profiles. Keep deterministic
XCTest fixtures separate from opt-in signed public-demo checks and account flows.

## Constraints and review focus

- Use macOS 27 evidence only; no release/macOS 26 claims.
- Do not use personal credentials, subscriptions, or remote participants.
- Require advancing decoded video and no error; encrypted claims require keys.
- Exercise cancellation, capture stop, reconnect, seek, captions and interruption
  where prerequisites permit; identify every remaining prerequisite.
- Bound asynchronous checks and tear down owned tabs, peers, stores and processes.
- Review the latest PR diff, require green CI and squash-merge under AGENTS.md.

## Execution

- [x] Audit baseline/environment and request designated test resources.
- [x] Add DRM evidence regressions; observe failure, correct clear/protected wording,
  and run `swift test --filter DRMPlaybackEvidenceTests`.
- [x] Add deterministic real-WebKit synthetic call lifecycle coverage for canvas
  video, peer reconnection/interruption and explicit source stop.
- [x] Add an opt-in signed public-media check using the Shaka demo's assets,
  with sampled sustained playback, pause/seek/resume, available captions and reload.
- [x] Run focused fixtures and signed public probes; record exact binary/source,
  environment, outcomes and limits in the compatibility log.
- [ ] Open PR, obtain independent review, fix findings, confirm required checks,
  squash-merge and verify cleanup of task-owned fixtures/apps.

Account sign-in and cross-network tasks depend on resources identified by the
user. Their absence is an unverified outcome, never a fixture pass.
