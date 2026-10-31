# Nightly Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offer an opt-in Nightly channel and publish signed nightlies only for changed, checked main commits.

**Architecture:** Keep one app and its existing installer. A pure channel policy selects stable releases or stable/nightly candidates; channel-specific caches and request generations prevent cross-channel offers. Extend the existing release workflow with a lightweight nightly eligibility job before its shared signing and notarization job.

**Tech Stack:** Swift/AppKit/SwiftUI, Python standard library, GitHub Actions.

**Spec:** Approved conversation: Stable / Nightly in update settings, Stable by default; one signed nightly per night only with new changes and passing checks; no separate app.

## Global Constraints

- Preserve existing signature, archive, installer and downgrade protections.
- Stable is the default, including for manually downloaded nightly builds; opting in persists.
- Nightly accepts stable releases and specifically `-nightly.DATE.RUN` prereleases; RC/beta releases remain excluded.
- Nightlies use the next patch after stable tags, so stable versions outrank their preceding nightlies.
- Switching to Stable waits for a newer stable release; do not implement a downgrade.
- Reuse native settings controls and Vane's Reduce Motion/Battery Saver policy.
- Keep strict required `checks` and administrator enforcement enabled; independent review and integrated CI precede squash merge.

## Review Focus

- A slow reply from the previous channel must never cache or present an offer after switching.
- Malformed responses must not poison conditional-request caches.
- An unchanged commit, a pending/failed check, or a nightly dispatch from a feature branch must not publish.
- A failed publication retry must retain its version and the verified source revision.
- Stable and Nightly must never replace a newer installed app or interrupt an active installation.

### Task 1: Channel policy and updater integration

**Files:** Create `Sources/Vane/UpdateChannel.swift`, `Tests/UpdateChannel/main.swift`, `scripts/test-update-channel.py`; modify `Sources/Vane/Updater.swift` and `.github/workflows/checks.yml`.

**Interfaces:** `UpdateChannel` supplies persisted raw values, display names, API path, per-channel cache keys, and `release(from: Data) throws -> UpdateRelease?`. Existing `Release` remains the asset trust and install authority.

- [ ] Write production-policy fixtures for opt-in default, JSON filtering, numeric nightly ordering, stable promotion, malformed payloads, and cache separation; run and observe missing policy failure.
- [ ] Implement the policy and run the standalone Swift fixtures.
- [ ] Snapshot channel and request generation for each fetch; discard stale replies, scope cache keys, remember only valid payloads, invalidate pending offers on channel changes.
- [ ] Add integration XCTest coverage for changing channels with pending offers and in-flight requests; verify with focused Swift tests and existing updater checks.

### Task 2: Settings

**Files:** Modify `Sources/Vane/SettingsWindow.swift`.

**Interfaces:** Persist `UpdateChannel.preferenceKey`; notify `Updater.shared.channelChanged()` on selection changes.

- [ ] Add native Stable / Nightly picker next to automatic checks with a short explanation of early builds and return-to-stable behavior.
- [ ] Animate explanation changes with existing motion policy; keep manual checks available when automatic checking is disabled.
- [ ] Verify built settings with a rendered native fixture, including both selections.

### Task 3: Nightly publishing

**Files:** Modify `.github/workflows/release.yml`, `scripts/test-release-workflow.py`; create `scripts/prepare-nightly.py`, `scripts/test-prepare-nightly.py`; update README and `docs/RELEASING.md`.

**Interfaces:** Preparation emits eligibility and nightly tag/source SHA; the existing release job consumes these while retaining stable/tag release behavior.

- [ ] Add tests for exact main commit eligibility, newest check attempts, unchanged published commits, nightly version calculation, stable tag isolation, publication retries, and non-main rejection. Observe failures before implementing.
- [ ] Add daily schedule and manual channel input, read-only eligibility job, exact-source checks gating and unchanged-source skip.
- [ ] Reuse the existing signed/notarized build, smoke tests and packaging; publish prereleases with `--latest=false` and only push prepared tags after packaging succeeds.
- [ ] Run release and nightly fixtures and update user/release documentation.

### Task 4: Ship

- [ ] Run focused validation and diff checks; push a `codex/` branch and open a PR.
- [ ] Obtain independent review of current diff and address actionable findings.
- [ ] Require green integrated CI on latest target, required approvals, and mergeability; squash merge and verify commit.
- [ ] Verify task-owned test processes exited, archive this managed worktree, preserve recovery branch and report results.
