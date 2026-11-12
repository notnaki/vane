# Smooth Live Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Smooth continuous window and sidebar resizing without scaling or blank page strips, settling to an exact viewport on release.

**Architecture:** Add a native rolling viewport buffer for admitted visible WKWebViews during continuous drags. Geometry consumes already painted coverage while the next viewport paints asynchronously; existing exact programmatic and discrete sidebar-close paths remain available.

**Tech Stack:** Swift, AppKit, SwiftUI, WebKit, XCTest, ScreenCaptureKit.

**Spec:** `docs/superpowers/specs/2026-11-11-smooth-live-resize-design.md`.

## Global Constraints

- No scaling, page zoom changes, stretched snapshots, or background masking.
- Buffered responsive geometry may briefly run ahead of the visible edge; final viewport must be exact.
- Lookahead48–192pt, velocity horizon0.18s, refill at half-buffer remaining;250ms bounded paint watchdog.
- Preserve native pointer anchoring, split fractions, sidebar clamp/detent/collapse/persistence/accessibility and motion policy.
- Preserve strict settled-gutter+2pt coverage and all existing failure evidence.
- Native motion targets p95≤25ms, maximum≤80ms, step≤24pt; final screenshots must reflect exact geometry.

## Review Focus

- Fast reversal while a smaller buffered viewport is in flight must not expose its edge.
- Split pages paint independently; no geometry may exceed the least-covered page.
- Frame/root/page replacement and late callbacks must restore only state still owned.
- Release during paint must commit only the latest desired geometry and restore every native flag.
- Watchdog, window close/fullscreen and sidebar collapse must not leave an active coordinator or frozen page.

### Task 1: Buffered continuous resizing

**Files:** Create `Sources/Vane/LivePageResizeBuffer.swift` and `Tests/VaneTests/LivePageResizeBufferTests.swift`; modify `Sources/Vane/Window.swift`, `Sources/Vane/SidebarResize.swift`, `Sources/Vane/WindowResize.swift` only if shared layout metadata needs equality; update `Tests/VaneTests/WindowResizeResponsiveMotionTests.swift` and `Tests/VaneTests/WindowResizeLayoutTests.swift` for buffered endpoint readiness and continuous sidebar coverage.

**Interfaces:** A main-actor, failable buffer owns a visible window/root and admitted pages. It exposes start/prime, request desired window frame or sidebar width, finish exact viewport, cancel, and isPreparing. Presenter/deadline injections match WindowResizePreparation so deterministic tests can control paints and watchdogs. VaneWindow starts/forwards/ends it for native live resize and sidebar gestures; an apply callback publishes actual geometry, an isCurrent closure protects sidebar ownership, and a completion callback clears its owner. Exact internal signatures may be chosen together because this is one coupled component.

- [ ] Write deterministic tests for priming/covered immediate movement, bounded refill, baseline geometry/no cumulative lead, reversal, independent split paints, latest release endpoint, owner replacement and watchdog/late-callback cleanup.
- [ ] Implement the buffer and VaneWindow/sidebar gesture adapters. Keep original exact programmatic/discrete-close paths as fallbacks.
- [ ] Extend native coverage to continuous sidebar drags and await exact final buffer drainage before endpoint assertions. Retain assertion bounds.
- [ ] Run focused model tests with `python3 scripts/run-native-tests.py --jobs 4 --filter 'LivePageResizeBufferTests|PageResizeStyleTests|WindowResizePreparationTests|SidebarPageResizePreparationTests|SidebarResizeTests|SidebarResizeHighlightTests'`; require primary0/cleanup0.
- [ ] Review the complete task diff independently, fix actionable findings, and rerun covering checks.
- [ ] Coordinate final foreground paint/cadence captures with the controller; require original assertions and tighter p95 target. Do not call the work complete while actual cadence fails.

After the task: validate integration with current main, pass required CI/review, squash-merge PR658, verify and clean only this task's worktree and owned test processes.

### Task 2: Bound native sidebar publication work per display frame

Native profiling and the optimized capture show a separate UI graph bottleneck after page reflow is buffered: optimized sidebarp9525.34ms still exceeds25ms, while WebContent is96.7% idle. Window cadence and all painted coverage pass. Finish this remaining gate through frame-aligned width publication.

- [ ] Add a small owned sidebar width coalescer using a native per-window/screen CADisplayLink at60Hz, with an injectable frame driver for deterministic tests. Accept every input; each callback applies only the latest covered width without animation.
- [ ] Integrate only continuous admitted sidebar buffer publication. Flush latest covered width before release reconciliation; cancel pending values and invalidate the link on ownership loss or newer commands. Preserve exact buffer barriers, fallback behavior, resize detent/clamp/collapse/persistence/AX and discrete interactions.
- [ ] Write meaningful RED/GREEN models for multiple proposals per frame, release flush, cancellation/owner replacement, latest uncovered versus queued covered width and in-flight reversal. Keep all native bounds unchanged.
- [ ] Run covering resize/integration checks and independent source review; measure actual window/sidebar/coverage again. Debug and optimized RED evidence remains retained; no unchanged retry may count as a repair.

### Task 3: Honor covered native window display requests

The narrowed width build passes actual sidebar motion and all painted coverage. Window steady cadence passes but its first native move at~73ms reaches captured pixels at115ms. The existing commit path always passes displayfalse to AppKit and only marks views dirty.

- [ ] Use the existing actual WindowServer first-frame regression as RED evidence; preserve its maximum80ms and p95≤25ms assertions. Avoid a spy-only test that merely repeats the display call.
- [ ] Honor the display request synchronously after the admitted native frame change, preserving coverage and avoiding an additional root layout per input.
- [ ] Validate covering models/product/pure and independent review, then measure the unchanged first-visible and steady-motion bounds.
