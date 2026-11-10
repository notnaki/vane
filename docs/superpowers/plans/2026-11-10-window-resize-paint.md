# Window Resize Painting Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the existing isolated task worktree.

**Goal:** Keep page content at normal scale and drawn to the window edge during native resizing.

**Architecture:** Prepare WebKit's next viewport before committing the matching window frame. Defer native WebKit child-view autoresizing until the presentation callback, coalesce subsequent requests, and bound preparation so an unresponsive page cannot trap a resize.

**Tech Stack:** Swift, AppKit, SwiftUI, WebKit, XCTest, ScreenCaptureKit.

**Spec:** The user requires newly drawn content without scaling, native resize-edge behavior, and personal testing before merge. Captured ordinary-path regression is RED; the isolated preparation diagnostic is GREEN with the same edge assertion after restricting measurement to SCStream's valid content rectangle.

## Global Constraints

- No content transforms, page zoom, snapshot stretching, or background-color masking.
- Preserve the native resize edge and native drag event handling.
- Keep the PR draft until the production path passes and the user tests a fresh build.
- Coordinate only actual foreground/capture intervals; do not alter other tasks' apps or profiles.
- Preserve failed diagnostic evidence and original pixel tolerances.

## Review Focus

- Rapid requests: only the latest queued frame remains pending; callbacks cannot commit stale generations.
- Slow/terminated WebContent: a 100ms watchdog restores native sizing and falls back for that drag.
- Page/profile replacement: restore original native flags and reject a detached presentation owner.
- Split pages and Library: predict viewport deltas from current pane weights and the same navigation-width formula as SwiftUI.
- Window closure/fullscreen/programmatic geometry: cancel preparation without moving a closed/replaced window.

### Task 1: Native preparation and request queue

**Files:** Create `Sources/Vane/WindowResize.swift`; modify `Sources/Vane/Window.swift`.

**Interfaces:** `WindowResizePreparation.request(frame:display:) -> Bool` prepares a request or declines it; `cancel()` restores pending native state. `VaneWindow` forwards only native live-resize requests and commits prepared frames through a bypass method.

- [x] Capture the ordinary path failing the right-edge assertion with valid SCStream bounds.
- [x] Prove native child-view preparation against that same assertion in the isolated diagnostic.
- [ ] Implement one in-flight batch, one latest queued request, owner/generation checks, and the 100ms fallback.
- [ ] Add deterministic queue/cleanup tests and verify that a late callback cannot commit a canceled request.

### Task 2: Viewport sizing and production capture

**Files:** Modify `Sources/Vane/UI.swift`; create metadata in `Sources/Vane/WindowResize.swift`; update `Tests/VaneTests/WindowResizeLayoutTests.swift`.

**Interfaces:** `PageResizeLayout` supplies the navigation width for a proposed window width. Each `WebHost` supplies its split fraction and visible page targets. The window preparer consumes these native owners.

- [ ] Carry current sidebar/Library sizing and split weights into native WebHost metadata.
- [ ] Replace diagnostic-only preparation with the real production preparer in the pixel case.
- [ ] Verify ordinary RED and production GREEN, including grow/shrink, queued requests, and timeout/owner cleanup.
- [ ] Run focused native regressions and pure checks after integrating current main.

### Task 3: Personal preview

**Files:** PR #618 and tracked isolated test bundle/manifest.

- [ ] Obtain independent review of the final production diff and fix findings.
- [ ] Push/link the validated candidate while keeping PR draft.
- [ ] Replace only the tracked Resize Test copy with a newly identified isolated build.
- [ ] Wait for the user's personal result before merging.
