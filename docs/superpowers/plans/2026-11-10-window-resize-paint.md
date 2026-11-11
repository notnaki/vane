# Window Resize Painting Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the existing isolated task worktree.

**Goal:** Keep page content at normal scale and drawn to the window edge during native resizing.

**Architecture:** For growth, prepare WebKit's next viewport before committing the matching window frame. Defer native WebKit child-view autoresizing until the presentation callback, coalesce subsequent requests, and bound preparation so an unresponsive page cannot trap a resize. For shrink, let AppKit clip the existing page immediately and WebKit repaint normally; do not expose smaller content inside the previous larger window.

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
- Slow/terminated WebContent: a250ms watchdog restores native sizing and temporarily falls back; coordination resumes after every outstanding page paints.
- Page/profile replacement: restore original native flags and reject a detached presentation owner.
- Split pages and Library: predict viewport deltas from current pane weights and the same navigation-width formula as SwiftUI.
- Window closure/fullscreen/programmatic geometry: cancel preparation without moving a closed/replaced window.

### Task 1: Native preparation and request queue

**Files:** Create `Sources/Vane/WindowResize.swift`; modify `Sources/Vane/Window.swift`.

**Interfaces:** `WindowResizePreparation.request(frame:display:) -> Bool` prepares a request or declines it; `cancel()` restores pending native state. `VaneWindow` forwards only native live-resize requests and commits prepared frames through a bypass method.

- [x] Capture the ordinary path failing the right-edge assertion with valid SCStream bounds.
- [x] Prove native child-view preparation against that same assertion in the isolated diagnostic.
- [x] Implement one in-flight batch, one latest queued request, owner/generation checks, and the bounded fallback.
- [x] Add deterministic queue/cleanup tests and verify that a late callback cannot commit a canceled request.

### Task 2: Viewport sizing and production capture

**Files:** Modify `Sources/Vane/UI.swift`; create metadata in `Sources/Vane/WindowResize.swift`; update `Tests/VaneTests/WindowResizeLayoutTests.swift`.

**Interfaces:** `PageResizeLayout` supplies the navigation width for a proposed window width. Each `WebHost` supplies its split fraction and visible page targets. The window preparer consumes these native owners.

- [x] Carry current sidebar/Library sizing and split weights into native WebHost metadata.
- [x] Replace diagnostic-only preparation with the real production preparer in the pixel case.
- [x] Verify ordinary RED and production GREEN, including grow/shrink, queued requests, and timeout/owner cleanup.
- [x] Run focused native regressions and pure checks after integrating current main.

### Task 3: Personal preview

**Files:** PR #618 and tracked isolated test bundle/manifest.

- [x] Obtain independent review of the final production diff and fix findings.
- [ ] Push/link the validated candidate while keeping PR draft.
- [ ] Replace only the tracked Resize Test copy with a newly identified isolated build.
- [ ] Wait for the user's personal result before merging.

## Retained validation findings

Independent review of `063afee3..9d69a6cf` identified two stale-request races.
Both new regressions failed on the reviewed source; `e91ea7a5` rejects the
scheduled continuation after a newer programmatic frame/root change and rejects
paint/timeout callbacks from detached owners. All ten queue/cleanup tests and
the pure checks pass.

The cleaned production capture subsequently reproduced a real 40.29-point gap
(`/tmp/vane-resize-ready-current-pixel.log`, primary1/cleanup0). Earlier passing
captures did not resolve this failure; it prompted the shrink-order regression below.

The shrink-order regression failed on that source. The candidate uses ordinary
native clipping for shrink, including a reversal queued behind growth. Pixel
measurement counts both fixture body and marker as drawn content during clipping;
the final paint separately must place the fixed marker at the new viewport edge.
The same calibrated original path still fails (160.20pt browser /39.43pt control).
After integrating main `5cd5979a`, the predetermined hands-off sequence completed
in16.19s: original RED, candidate13/13PASS, second candidate pixel PASS. Browser
maximum gap1.86pt versus1.71pt settled gutter; native maximum0.0/0.86pt versus0.0pt.
Every wrapper verified cleanup0. Logs: `/tmp/vane-resize-shrink-validation-0.log`,
`-1.log`, `-2.log`; pure checks also pass. Personal native-drag preview remains open.

## Actual native-drag failure and recovery policy

The user rejected candidate02f7b73b: widening still exposed a bar. An opt-in
geometry-only trace of the real GitHub drag is retained at
`/tmp/vane-resize-actual-native-drag-red.log`. The second paint arrived116ms
after preparation. The100ms watchdog had already exposed a queued1274pt frame
while preparing1052pt;854 subsequent requests bypassed coordination over the
remaining11seconds. Event-tracking paint callbacks were delivered, so a missing
tracking-mode callback was not established as the cause.

Both new regressions failed on that source: normally late150ms paint must not
expose queued unpainted width; a genuine timeout must recover on late paint
without committing stale geometry. The candidate uses a250ms normal-paint budget
and tracks every outstanding split callback before clearing temporary fallback.
All13 preparation tests and pure checks pass on merged main8f0a6ef9. Read-only
independent review of this timeout/recovery diff found no actionable issues.
A real120ms busy resize-handler pixel fixture is compiled; its foreground
validation and the user's fresh native-drag preview remain pending.

## Responsive style equality improvement

Measured the true page-work bottleneck on private GitHub pages: inherited CSS custom-property equality during style changes. A harmless count change skips WebKit's deep comparison. Inline-root control/hint/control reduced steady width latency from154–178ms to15–16ms; a browser-owned constructed stylesheet preserved HTML attributes and every visible style/geometry fingerprint while reducing169–184ms to41–46ms.

Implement the safer stylesheet path only on variable-heavy documents. Keep the existing paint-before-growth coordinator and exact responsive viewport. Use two private unused entries to avoid cancelling ordinary one-entry media-query changes. Keep one reusable sheet per document and clear active declarations after the final live-resize preparation or cancellation. Preserve author stylesheets, navigation ownership, and page zoom.

Required checks: production preparation latency regression RED171ms vs70ms bound; GREEN candidate with identical bound; local private-page visual/style/attribute and cleanup invariants; original16 native sizing/coverage cases; visible WindowServer motion on the real responsive workload; fresh personal preview. No push/fullCI/base/merge without coordinator authorization. Latest user directive prohibits cross-agent messages; results stay in this thread.


## Sidebar-close coverage and remaining smoothness

User tested the live-media optimization and reports an overall improvement, but still sees a right strip specifically while closing the sidebar. They do not identify a single hitch. This transition changes the internal page width without an outer window proposal, bypassing WindowResizePreparation. First reproduce with actual WindowServer pixels on the real BrowserWindowHost, while leaving the window frame unchanged and asserting normal page zoom. Preserve the strict settled-gutter+2pt coverage bound and a final fixed-right marker.

If reproduced, prepare the final viewport before beginning the discrete sidebar close, with cancellation/reversal/owner guards and ordinary brief sidebar animation. Keep the accepted live responsive window drag; do not hold a wider layout for its duration or scale page content. Measure any further per-frame optimization before adopting it. No full CI/push/base/merge without central authorization; personal approval still pending.


### 2026-11-11 tested checkpoint and pause

The sidebar-close regression reproduced216pt of unpainted width. Prepare the final viewport before publishing the close, retain native sizing through the slide, and give painting and configured animation separate generation-guarded deadlines. The first candidate's64pt residual strip was traced to the paint watchdog firing during the legitimate slide; a deterministic model reproduced the same early restoration. An additional half-point endpoint regression prevents applying the final parent delta twice.

Restored checkpoint:30 unshown model/style/zoom cases PASS, primary0/cleanup0; all4 strict native viewport/coverage cases PASS, primary0/cleanup0. Sidebar maximum gap1.7142858pt equals its settled gutter; exact final viewport878pt. Ordinary window browser gap1.714pt/native0;120ms busy-handler browser maximum1.857pt versus1.714pt settled/native0. Bounds unchanged. Receipts are preserved at `/Users/nuh/.t3/userdata/artifacts/vane-resize-sidebar-checkpoint-20261111`.

Overall window smoothness remains user-gated. The earlier actual WindowServer motion check retained an initial93.86ms pause against80ms; p9557.79ms/maxstep20pt passed their bounds. No repaired-cadence or READY claim. Latest user says improved but still room for improvement. A directional hint-band experiment reduced deterministic stylesheet refreshes but did not improve the controlled aggregate timings (mean17.87ms control versus18.77ms candidate); archived and reverted. The restored source is the state validated by the30-model/4-native pass, rather than that experiment. Current compiled build products include the later archived experiment and must not be packaged as this checkpoint without rebuilding.

Coordinator requested a usage pause: no further optimization, tests, captures, previews, delegates, push, CI, base update or merge now. Keep #618 draft and preserve the existing isolated preview. Fresh independent review and personal outer-window approval remain pending.
