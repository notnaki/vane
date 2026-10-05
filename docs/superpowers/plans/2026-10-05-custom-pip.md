# Custom Picture in Picture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution or superpowers:subagent-driven-development if the user selects that approach. Steps use checkbox syntax for tracking.

**Goal:** Present the site's existing live video in a freely positioned Vane window with custom controls and an in-place fade back to its source tab.

**Architecture:** Preserve the selected WebKit media element and its playback session. A presentation owner discovers and hosts the existing WebKit presentation view in an AppKit panel; separate controls query and command that exact video through the isolated bridge. A live hosting checkpoint comes first, and failure at that checkpoint stops replacement of the existing player.

**Tech Stack:** Swift 6, AppKit, WebKit, XCTest, macOS 26 or later. No additional playback engine or media extraction service.

**Spec:** `docs/superpowers/specs/2026-10-05-custom-pip-design.md`

## Global Constraints

- Do not snap to corners.
- Preserve existing manual PiP, automatic PiP, and sidebar restore behavior.
- Playback continues on Back to Tab and Minimize; Close pauses the selected video.
- There must be no visible native fly-back animation.
- Merely overlaying a native PiP window does not satisfy this design.
- All currently working sites remaining playable is the release target, not an already verified guarantee.
- If the custom host cannot attach safely, leave the existing native PiP working and clean up all partial custom state.
- Track and quit every task-owned test application after merge or abandonment.
- Preserve unrelated local changes; use branch `codex/custom-pip` in the attached worktree.

## Review Focus

1. A player replaces or removes its iframe during playback: stale callbacks must not control a main-frame decoy or create another floating window.
2. A tab navigates or closes during the opening or fading transition: presentation ownership and views must be released exactly once.
3. A live stream has an infinite duration or discontinuous seekable ranges: seeking must be disabled or bounded to a real range.
4. Two videos enter PiP almost simultaneously: ambiguous native-window ownership must leave native presentation intact.
5. A display disappears or the source browser window is minimized: the player must remain recoverable, and Back to Tab must reveal the right Space, tab, and window.

## File Responsibilities

- `Sources/Vane/CustomPiPWindow.swift`: AppKit floating panel, video container, drag and aspect-preserving resize, opacity-only dismissal.
- `Sources/Vane/PiPPlaybackControls.swift`: glass header, transport buttons, seek slider, control visibility, accessibility, adaptive layout.
- `Sources/Vane/PiPMinimizeControls.swift`: retain the existing integration entry points; manage per-tab presentation ownership, guarded attachment and teardown, and native fallback.
- `Sources/Vane/PictureInPicture.swift`: isolated selected-video query/command bridge and return/minimize coordination.
- `Sources/Vane/Engine.swift`: source-frame reports, presentation-state changes, and routing to the presentation owner if needed.
- `Tests/VaneTests/MediaControlsWebKitTests.swift`: extend real WebKit fixtures for hosting and media commands.
- `Tests/VaneTests/CustomPiPWindowTests.swift`: window geometry, layout, transitions, and ownership regressions.
- `README.md`: describe shipped behavior and any verified limitations.

---

### Task 1: Prove live video hosting and reversible ownership

**Files:**
- Create: `Sources/Vane/CustomPiPWindow.swift`
- Modify: `Sources/Vane/PiPMinimizeControls.swift`
- Test: `Tests/VaneTests/MediaControlsWebKitTests.swift`

**Interfaces:**
- Consumes: `PiPMinimizeControls.prepare(for: Tab)`, `install(for: Tab)`, and `remove(UUID)`; `Tab.pictureInPicture`, `Tab.web`, and `Tab.pipFrame`.
- Produces: `CustomPiPWindow: NSPanel` with identifier `vane.pip.window`; `init(frame: NSRect, videoView: NSView)`; the owning attachment stores the original parent and video frame, provides `remove()`, and restores them before disposal.
- Preserve `PiPMinimizeControls.Attachment(window:tab:)` and `update(pointer:)` for the existing native fallback tests until the custom-host checkpoint passes.

- [ ] **Step 1: Run the clean baseline and save complete output.**

```sh
swift build -c debug > /tmp/vane-custom-pip-baseline-build.log 2>&1
swift test > /tmp/vane-custom-pip-baseline-tests.log 2>&1
```

Expected: successful build and suite. Read the logs, including any skipped WebKit tests. Report any pre-existing failures before attributing failures to this change.

- [ ] **Step 2: Add a failing real-WebKit custom-host regression inside `MediaControlsWebKitTests`.**

```swift
func testPiPUsesAVisibleCustomHostInsteadOfVisibleNativeChrome() async throws {
    let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
    try await wait {
        try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false
    }
    PictureInPicture.toggle(tab)
    try await wait { tab.pictureInPicture }
    try await wait {
        NSApp.windows.contains {
            $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible
        }
    }
    XCTAssertFalse(NSApp.windows.contains {
        NSStringFromClass(type(of: $0)) == "PIPPanel" && $0.isVisible
    })
    let custom = try XCTUnwrap(NSApp.windows.first {
        $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible
    })
    custom.setFrame(NSRect(x: 350, y: 260, width: 480, height: 270), display: true)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(custom.frame.origin, NSPoint(x: 350, y: 260))
    XCTAssertTrue(tab.pictureInPicture)
    var minimized = false
    PictureInPicture.minimize(tab) { minimized = $0 }
    try await wait { minimized && !tab.pictureInPicture }
    XCTAssertFalse(custom.isVisible)
    let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
    XCTAssertEqual(paused, false)
}
```

This catches continuing to use native PiP, corner snapping, losing the active presentation on rehosting, or pausing during return. The constant blue fixture does not prove live frame updates; Step 5 is mandatory.

- [ ] **Step 3: Run the regression and verify the expected missing-host failure.**

```sh
swift test --filter MediaControlsWebKitTests/testPiPUsesAVisibleCustomHostInsteadOfVisibleNativeChrome
```

Expected: timeout waiting for `vane.pip.window`, because the current implementation only adds a small control panel over native PiP.

- [ ] **Step 4: Implement the smallest reversible hosting experiment.**

Create a nonactivating, borderless, resizable `CustomPiPWindow`; set its identifier, floating level, black background, stable aspect ratio, and join-all-Spaces/full-screen-auxiliary behavior. Add the discovered `WebVideoViewContainer` to its content view with width/height autoresizing. Keep a strong reference to the view and original parent until restoration; keep the original window weak. Hide the native host only after the custom view has attached, and make all failure paths restore the original host.

Use these AppKit settings as the starting point:

```swift
identifier = NSUserInterfaceItemIdentifier("vane.pip.window")
isReleasedWhenClosed = false
hidesOnDeactivate = false
isOpaque = false
backgroundColor = .black
level = .floating
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
contentAspectRatio = videoView.bounds.size
videoView.autoresizingMask = [.width, .height]
contentView?.addSubview(videoView)
```

Guard zero dimensions, missing layer/view, changed tab web view, and ambiguous ownership. Preserve the existing bounded discovery retries and never select a window already owned by another presentation. Do not rely on the native window remaining visible after attachment when tracking custom ownership. Restore the original host and video view before asking WebKit to end its presentation if its teardown needs them.

- [ ] **Step 5: Verify live pixels, entry, resize, and return on the desktop.**

Build an isolated test app using `./make-app.sh debug`, record its absolute bundle path and each launched PID/start time, and use an isolated `VANE_DATA_DIR`. Open an ordinary moving video and an embedded video already known to work in baseline Vane. Observe visibly changing frames in the custom window at its initial size and after resizing. Move it to the screen center and release it; verify it stays there. Return inline and verify video keeps advancing. Observe both entry and exit for duplicate native windows or blank flashes. Verify playback-time advancement separately through the WebKit fixture.

Expected: live changing pixels, no visible native host, arbitrary position retained, and working return. If rehosting is blank, frozen, intercepted by PIPAgent, or cannot keep native presentation invisible, restore the existing implementation and report the failed hosting checkpoint before attempting Tasks 2–4. Audio/time advancement alone is not a pass.

- [ ] **Step 6: Add teardown and ambiguous-ownership regressions, then commit the verified host.**

Test tab closure and navigation during discovery by requesting PiP and calling `tab.tearDown()` or `tab.web.loadHTMLString(...)` before attachment completes; after callbacks settle, assert no visible `vane.pip.window`. Test native-host discovery with two newly eligible windows: no custom attachment may be selected until ownership is unambiguous. Assert restoration leaves no detached retained view or orphan panel.

```sh
swift test --filter MediaControlsWebKitTests
git add Sources/Vane/CustomPiPWindow.swift Sources/Vane/PiPMinimizeControls.swift Tests/VaneTests/MediaControlsWebKitTests.swift
git commit -m "Host live PiP video in a freely positioned Vane window"
```

Expected: media suite passes, including the live hosting checkpoint; commit only the task's files.

### Task 2: Add selected-video transport and seeking

**Files:**
- Modify: `Sources/Vane/PictureInPicture.swift`
- Test: `Tests/VaneTests/MediaControlsWebKitTests.swift`

**Interfaces:**
- Consumes: the isolated script's `presented` media element and `Tab.pipFrame`.
- Produces: `PictureInPicture.Playback` with `playing: Bool`, `position: Double`, `duration: Double?`, and `ranges: [ClosedRange<Double>]`; `playback(_ tab: Tab, then: @escaping @MainActor (Playback?) -> Void)`; `control(_ command: Control, tab: Tab, then: (@MainActor (Bool) -> Void)? = nil)`; `Control` cases `playpause`, `skip(Double)`, and `seek(Double)`.
- JavaScript query helper: `__vanePiPPlayback()`; command helper: `__vanePiPControl(command, value)`. Invoke with `callAsyncJavaScript` arguments rather than interpolating positions into source strings.

- [ ] **Step 1: Add failing tests for exact-video commands and unsupported seeks.**

Start the existing iframe fixture with a paused main-frame decoy. Enter iframe PiP through the site's video element. Call `control(.playpause, tab: tab)`, assert iframe video pauses and decoy remains paused, call again, and assert iframe resumes. Seek to a valid position and assert the chosen element's `currentTime` changes; assert the decoy's does not. Query state and compare its position/playing values with the real element. Remove the iframe, send another command, and assert completion is false and the decoy remains paused.

For finite fixtures, use values shorter than the existing two-second clip:

```swift
PictureInPicture.control(.seek(0.75), tab: tab)
try await wait {
    let position = try await tab.web.evaluateJavaScript(
        "document.getElementById('embedded').contentDocument.getElementById('player').currentTime"
    ) as? Double ?? -1
    return position >= 0.7
}
```

Add `.seek(.nan)`, `.skip(.infinity)`, and empty-seekable-range cases; each must fail without changing the selected video. Use a Media Source or live fixture for nonfinite duration and explicit disjoint seekable ranges in the parsed state; playback state must still show while unsupported seeking stays disabled.

- [ ] **Step 2: Run the new tests to verify missing bridge behavior.**

```sh
swift test --filter MediaControlsWebKitTests
```

Expected: new bridge tests fail because the query/commands do not yet exist; existing media regressions remain documented.

- [ ] **Step 3: Implement the selected-element bridge and bounded parser.**

The command helper requires `presented && presented.isConnected`; no fallback to `biggest()` is allowed for controls. Toggle play/pause on that element and await `play()`. Query its current state and actual seekable ranges. Parse only finite nonnegative times, cap accepted range count, and discard malformed ranges. Clamp valid seeks to an actual seekable range; absolute seeks into gaps select the nearest range boundary. Relative skips use `currentTime + value`, bounded to real seekable ranges. Return false for invalid numeric input or removed frames.

```javascript
async function control(command, value) {
  var v = presented && presented.isConnected ? presented : null;
  if (!v) { return false; }
  if (command === 'playpause') {
    if (v.paused || v.ended) { await v.play(); } else { v.pause(); }
    return true;
  }
  if (!Number.isFinite(value) || !v.seekable.length) { return false; }
  var wanted = command === 'skip' ? v.currentTime + value : value;
  if (command !== 'skip' && command !== 'seek') { return false; }
  var best = null, distance = Infinity;
  for (var i = 0; i < v.seekable.length; i++) {
    var candidate = Math.min(v.seekable.end(i), Math.max(v.seekable.start(i), wanted));
    if (Math.abs(candidate - wanted) < distance) {
      best = candidate; distance = Math.abs(candidate - wanted);
    }
  }
  if (!Number.isFinite(best)) { return false; }
  v.currentTime = best;
  return true;
}
```

Guard every callback with the captured web view identity and presentation generation so a response after navigation cannot change the controls for a newer player.

- [ ] **Step 4: Run the bridge and full media regressions and commit.**

```sh
swift test --filter MediaControlsWebKitTests
git add Sources/Vane/PictureInPicture.swift Tests/VaneTests/MediaControlsWebKitTests.swift
git commit -m "Control the selected PiP video and bound seeking to its timeline"
```

Expected: commands affect only the selected video, malformed/nonfinite values are rejected, and existing minimize/return regressions pass.

### Task 3: Build responsive custom controls and in-place dismissal

**Files:**
- Create: `Sources/Vane/PiPPlaybackControls.swift`
- Modify: `Sources/Vane/CustomPiPWindow.swift`, `Sources/Vane/PiPMinimizeControls.swift`, `Sources/Vane/PictureInPicture.swift`
- Create: `Tests/VaneTests/CustomPiPWindowTests.swift`
- Modify: `Tests/VaneTests/MediaControlsWebKitTests.swift`

**Interfaces:**
- Consumes: Task 1's custom panel and presentation owner; Task 2's `Playback`, `playback(_:then:)`, and `control(_:tab:then:)`; existing `MediaState.shared.minimize`, `dismiss`, and `returned(to:)`.
- Produces: `PiPPlaybackControls: NSView`, `init(tab: Tab, returnToTab: @escaping () -> Void, minimize: @escaping () -> Void, close: @escaping () -> Void)`, and `update(_ state: PictureInPicture.Playback)`; `CustomPiPWindow.fadeOut(completion: @escaping @MainActor () -> Void)` with opacity-only animation.

- [ ] **Step 1: Add failing geometry and return regressions.**

Create window tests using an ordinary `NSView` video host; set origin to `(350, 260)` and size to `480 × 270`. During `fadeOut`, sample `frame` and assert it never changes. Await completion and assert the window is hidden. For geometry/layout, inspect hit-testable controls at the chosen minimum width and a large width; assert the frames stay inside bounds and header controls do not overlap. Resize to portrait and landscape aspect ratios and verify the host fills the video bounds without distorting its ratio. Include a display-removal recovery case using a supplied list of visible screen frames in a pure geometry helper.

Extend the existing real-WebKit restore test to click `vane.pip.restore` and assert source tab/Space selected, minimized source browser window restored, video still playing, custom panel hidden, and automatic PiP suppression cleared. Record the custom window's frame before click and assert it remains the same throughout the fade.

```swift
let originalFrame = panel.frame
restore.performClick(nil)
while panel.isVisible {
    XCTAssertEqual(panel.frame, originalFrame)
    try await Task.sleep(for: .milliseconds(20))
}
XCTAssertEqual(store.current, tab.id)
```

Also start fading, then tear down the source tab before completion; assert no delayed tab activation and no orphan custom panel.

- [ ] **Step 2: Run the new tests before implementation.**

```sh
swift test --filter 'CustomPiPWindowTests|MediaControlsWebKitTests'
```

Expected: missing controls/fade behavior fails the new regressions.

- [ ] **Step 3: Implement the window controls and animations.**

Use `NSGlassEffectView` with dark appearance for the rounded header buttons. Keep existing identifiers `vane.pip.restore` and `vane.pip.minimize`; add `vane.pip.close`, `vane.pip.playpause`, `vane.pip.backward`, `vane.pip.forward`, and `vane.pip.seek`. Use SF Symbols `arrow.up.left`, `minus`, `xmark`, `play.fill`/`pause.fill`, `gobackward.15`, and `goforward.15`. The seek slider sends an absolute seek on user interaction and is disabled when no valid range exists. Adaptive header layout removes text labels before allowing buttons to overlap; never remove accessibility names.

Allow background dragging through `performDrag(with:)`; button/slider hit targets retain their own mouse handling. Set a minimum content size and retain aspect ratio while resizing. Track hover and keyboard focus with AppKit tracking areas and responder state. Keep controls visible while interacting, and use short opacity transitions for visibility. Poll state only while the owner is active, avoid overlapping requests, and cancel the poll on teardown.

Fade dismissal must change opacity only:

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
    animator().alphaValue = 0
} completionHandler: {
    Task { @MainActor in
        self.orderOut(nil)
        completion()
    }
}
```

Before invoking a fade completion, verify the owner is still current and the captured tab web view is unchanged. Back to Tab then restores the live host as required, requests inline without pause, clears minimize suppression through the existing helper, calls `MediaState.shared.returned(to:)`, and reveals/activates the source tab. Keep native exit presentation invisible. If inline fails, recover the visible custom player rather than claiming success. Minimize retains the existing sidebar behavior; Close uses the existing source-specific pause/dismiss behavior.

- [ ] **Step 4: Update obsolete native-overlay expectations and verify the new lifecycle.**

Replace tests that require a visible `PIPPanel` with assertions on the custom panel and its live video host. Retain a separate fallback test proving native controls remain usable when a host cannot attach. Add return/minimize/close during transition, removed-frame, and repeated-entry tests. Existing tests for ad-frame selection and returning to an already selected tab must continue to pass.

```sh
swift test --filter 'CustomPiPWindowTests|MediaControlsWebKitTests'
git add Sources/Vane/CustomPiPWindow.swift Sources/Vane/PiPPlaybackControls.swift Sources/Vane/PiPMinimizeControls.swift Sources/Vane/PictureInPicture.swift Tests/VaneTests/CustomPiPWindowTests.swift Tests/VaneTests/MediaControlsWebKitTests.swift
git commit -m "Add custom PiP transport controls and fade back to the source tab"
```

Expected: custom controls, exact source routing, geometry, transition cancellation, and fallback tests pass.

### Task 4: Validate compatibility, document results, review, and merge

**Files:**
- Modify: `README.md`
- Modify if a regression is discovered: the exact owning production and test files from Tasks 1–3.

**Interfaces:**
- Consumes: all custom-presentation interfaces and the original native fallback.
- Produces: a reviewed PR with compatibility evidence, passing required checks, a squash merge, and no task-owned test processes left running.

- [ ] **Step 1: Exercise the supported-site matrix using baseline and changed builds.**

Test moving plain video, authenticated Media Source/blob video, cross-origin embedded video, and a protected-video site that already works in baseline. For each, record baseline result, custom-window result, live-frame changes, play/pause, backward/forward seek, seek slider, resize, arbitrary placement, minimize/restore, Back to Tab, and close. Include full-screen Spaces, an external display, and source-browser minimization. If a required site/account/display is unavailable, record that limit explicitly; it is not a pass. Do not expose authentication credentials in logs or evidence.

- [ ] **Step 2: If a real regression is found, write its failing test before fixing it.**

For native fallback, make attachment ineligible without disabling baseline WebKit PiP and assert native presentation still works and custom panels/tasks are absent. For simultaneous entry, navigate/remove one source before attachment and assert the surviving player's commands still target its source. Follow RED→GREEN for each discovered failure, then repeat the relevant media tests.

- [ ] **Step 3: Update the README to match verified behavior.**

Replace the current PiP paragraph with the actual custom-placement/control behavior and any observed native fallback or protected-video limitations. Do not claim every site is supported unless that claim is justified; report the tested matrix and limits in the PR description.

- [ ] **Step 4: Run the documented validation commands and inspect results.**

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
swift test
scripts/check-app-icons.sh
scripts/check-cloud-ai.sh
bash scripts/test-cli-import.sh .build/debug/vane
python3 scripts/test-ci-source-state.py
python3 scripts/test-release-workflow.py
./make-app.sh debug
python3 scripts/test-default-browser-prompt.py
./scripts/test-build-dmg.sh
bash scripts/test-update-installer.sh Vane.app --unsigned
```

Expected: successful build and checks; report every failure, skipped check, or unavailable service. Run the signed isolated browser smoke script when needed to verify real WebKit behavior outside XCTest. Capture full output in logs and inspect summaries rather than flooding the conversation.

- [ ] **Step 5: Commit, push, create the PR, and attach it to this chat.**

```sh
git add README.md
git commit -m "Document verified custom PiP behavior"
git push -u origin codex/custom-pip
```

Use `gh pr create` with an exact body file containing the problem, shipped behavior, validation results, compatibility matrix, and remaining material limits. Attach the created PR using `attach_artifact`. Expected: one task-specific PR against `main`, excluding the unrelated toast changes in the primary checkout.

- [ ] **Step 6: Obtain independent review of the current PR diff and resolve findings.**

Use a review subagent as required by `AGENTS.md`, providing the approved spec, this plan, latest head SHA, and Review Focus. Address actionable findings, push fixes, rerun relevant validation, and repeat review until the latest head has no unresolved actionable findings. Do not substitute author self-review for independent review.

- [ ] **Step 7: Verify merge conditions, squash-merge, and clean up tracked test instances.**

Inspect the latest PR head, review evidence, required approvals, CI checks, and mergeability. A pending or unavailable check/review is a blocker. Once all requirements pass, squash-merge according to standing project instructions, verify the merged state and squash SHA, and quit only the recorded task-owned test instances. Handle quit confirmation or revalidate PID/executable/start time before an authorized targeted TERM/KILL fallback. Verify exits. Report PR URL, squash commit, validation, compatibility limits, and cleanup.

## Plan Self-Review

The live-host experiment gates all product replacement. Exact media-source routing,
nonfinite timelines, transition cancellation, ambiguous entry, and display loss are
covered by their owning tasks. Entry points retain their existing names; Task 3
uses only the window and playback interfaces produced by Tasks 1 and 2. The plan
does not assume protected playback or private-view rehosting works before testing.
Independent review and squash-merge follow `AGENTS.md`, including re-review of
fixes even if another process skill suggests a single review pass.
