# Meet call pop-out implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Keep a Meet call and its controls visible in a floating window after leaving its tab, with an animated call indicator in the sidebar.

**Architecture:** Detect Meet's visible hang-up control in an isolated content world. Move the existing WKWebView into a native floating panel, preserving the document and its controls, then return it to its normal host. Reuse the automatic PiP preference and tab-switch/minimize entry points.

**Tech stack:** Swift, AppKit, SwiftUI, WebKit, XCTest.

**Spec:** User's screenshot and recording in this conversation; user authorized immediate implementation.

## Constraints and review focus

- Scope automatic call detection to HTTPS `meet.google.com`; a lobby camera preview is not a call.
- Keep muted/camera-off calls alive; closing the pop-out hides it without hanging up.
- Never let stale messages or background hosts steal a floating page; shared windows and split panes retain their existing ownership rules.
- Tab return, call end, navigation, process loss, and tab closure release the panel correctly.
- Respect Reduce Motion and Battery Saver; synthetic fixtures do not establish live Meet compatibility.

## Task 1: Detect active calls

Files: `Sources/Vane/MeetCall.swift`, `Engine.swift`, `MediaPlayer.swift`, `Suspension.swift`; `Tests/VaneTests/MeetCallTests.swift`.

- [x] Add failing native tests for lobby, visible/hidden hang-up controls, SPA join/leave, navigation, and unrelated origins.
- [x] Run `python3 scripts/run-native-tests.py --jobs 1 --filter MeetCallTests` and confirm the feature is missing.
- [x] Add an isolated Meet-only observer and document-bound messages, publish `Tab.inMeetCall`, and protect active calls from suspension/offscreen removal.
- [x] Run focused tests and confirm detection and cleanup.

## Task 2: Present the floating call and tab indicator

Files: `Sources/Vane/CallPopout.swift`, `PictureInPicture.swift`, `UI.swift`; `Tests/VaneTests/MeetCallTests.swift`.

- [x] Add failing tests for live web-view identity, source host contention, automatic/manual return, dismissal suppression, preference off, split/shared ownership, and call-end/tab-close cleanup.
- [x] Implement the resizable floating panel, Back to Tab and Close controls, host exclusion/return, and integration with automatic/video PiP commands.
- [x] Add the yellow camera and pulsing red in-call indicator, with accessible meaning and reduced-motion behavior.
- [x] Verify an actual synthetic WebRTC call continues delivering frames and its controls work after pop-out and return.

## Task 3: Validate and land

- [x] Run focused call/media/host/suspension tests and a build; inspect the diff and document compatibility bounds.
- [ ] Commit, push, create/link PR, obtain independent whole-diff review, fix findings, and run required CI.
- [ ] Refresh the PR and target CI immediately before squash merge; verify merge and clean task-owned worktree/build processes.
