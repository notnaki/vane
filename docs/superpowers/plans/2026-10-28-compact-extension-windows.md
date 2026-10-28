# Compact Extension Windows Implementation Plan

**Goal:** Present extension actions in compact native windows while preserving their exact SDK webview, originating tab, profile, and permissions.

**Architecture:** Keep action presentation separate from browser-window adapters. A small window owner handles presentation, delegate forwarding, sizing, and closure. Explicit extension-requested popup windows use their own truthful window/tab adapters.

**Spec:** User's compact native extension-window request and parent task scope, 2026-10-28.

**Constraints:** System WebKit on macOS 26+. No native-messaging or grant changes. No vendor-code changes. Preserve SDK delegates and origin boundaries. Do not stage, commit, or push this work; the parent task owns integration. Preserve unrelated CI changes.

## Review focus

- Repeated activation and JavaScript closure must not retain a closed SDK popup.
- A key action window must retain its originating browser tab/profile.
- SDK delegates must continue handling links, loading, and renderer failure.
- Requested popup geometry may contain omitted NaN components.
- Disable, parent closure, and profile removal must release owned windows.

## Tasks

- [x] Add native action-window controls; run against the current implementation and preserve the failing result.
- [x] Implement action window ownership in `Sources/Vane/ExtensionWindows.swift` and connect it in `Extensions.swift`. Preserve the existing options-page path.
- [x] Add requested-popup controls; implement a single own-extension URL popup with truthful adapters, explicit unsupported errors, and bounded finite geometry.
- [x] Run focused extension-window, lifecycle, permission, and user-agent validation. Update the older user-agent presentation assertion for the new visible owner. Inspect the final diff and report evidence to the parent; leave changes uncommitted.

Native tests use `python3 scripts/run-native-tests.py --filter ...`, real AppKit loop admission, exact visible-window ownership, foreground prerequisites, and bounded observable waits. The native runner records and retires its exact test-host processes and stores. No separate Vane app copy is needed.

## Validation and review evidence

On 2026-10-29, the independent review's cached-focus and stale-parent-observer findings both reproduced in native controls before the corresponding fixes. Actions now synchronize the SDK's cached focus/events on native key transitions, and parent rebinding replaces the exact native-window close observer without crossing profile/private boundaries.

The final focused cohort (`ExtensionWindowTests|ExtensionLifecycleTests|ExtensionRuntimePermissionTests|ExtensionUserAgentTests`) ran 38 tests with no failures. The sole existing skip was `ChromeExtensionLifecycleTests.testRealStoreDownloadAndBackgroundWhenRequested`, requiring `VANE_STORE_LIVE_CHECK=1`. All six new window controls passed. Primary status 0, cleanup status 0; 42 exact owned backends verified absent and all test processes exited.

The grant fixture declares `activeTab`, admits live parent/sibling documents, and checks per-tab access plus sibling, cross-tab, global-host, and native-messaging denial. It explicitly denies any additional native URL permission prompt from WebKit's `tabs.query`; one such prompt was observed. It compares each close interval without an intervening gesture. The older global-pattern observation is retained and is not described as a normal temporary tab grant.

Logs, before-review source snapshots, the original unrelated native crash, and the permission-path explanation are preserved under `/Users/nuh/.codex/artifacts/vane-extension-repair-2026-10-28/window-review-2026-10-29/`. The qualified CI admission-helper changes belong to the separate CI integration work and must not be staged with this feature. No changes here were staged, committed, or pushed by the window implementer.
