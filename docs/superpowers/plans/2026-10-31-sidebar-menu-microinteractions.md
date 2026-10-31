# Sidebar and menu microinteractions

**Goal:** Extend Vane's everyday feedback across tabs, folders, favourites, the Space header, and custom menus.

**Architecture:** Keep existing native event monitors and activation paths. Animate decoration only; keep row geometry, editors, hit targets, and focus owners stable. Use existing SwiftUI timing and motion policies, without dependencies or continuous effects.

**Spec:** User request to add more microinteractions, especially tabs, folders, and menus; repository AGENTS.md motion and integration requirements.

## Motion thesis

- Feedback: immediate sidebar press ink followed by a short release fade, shared by tab/folder rows and favourite tiles.
- Continuity: the closed folder's existing flap anticipates opening slightly on hover, then continues into the normal disclosure shape. Locked folders and drag previews retain their actual state.
- Menus: one pointer highlight moves between items; keyboard navigation stays immediate. Entrance originates at the trigger and finishes immediately if motion policy changes.
- Space header: short fades connect its icon, disclosure, and hover background. The native Space options trigger keeps main’s whole-Menu visibility and focus behavior.
- Copy Link: per the user's follow-up, accelerate the link-to-checkmark replacement and return to the link sooner. Use adaptive neutral primary ink for the checkmark, without the blue accent. Frequent feedback uses 120ms easing; button release uses a 160ms spring.
- Budget: animate paint only on affected controls; no timers per row, new event monitors, or animated layout.

## Constraints and review focus

- Respect Reduce Motion and Battery Saver, including policy changes during an effect.
- Preserve normal selection, child controls, modifier clicks, drag cancellation, double-click rename, and locked-folder behavior.
- Preserve row/inline-editor identity, native focus, and full hit targets.
- Menus must retain immediate dismissal, typeahead, keyboard selection, clipping, and action-once semantics.
- The existing preview app is tracked separately and must be retired before rebuilding it; preserve the user's regular app.

## Tasks

- [x] Add native regression coverage for sidebar press release/policy cancellation; observe the missing feedback on the base implementation. Inspect folder-hover rendering in the running app.
- [x] Extend the shared press decoration and apply it to favourites. Add a hover preview to the existing folder shape and smooth the Space header's decorative states.
- [x] Implement the shared menu highlight and interruption-safe anchored reveal; validate highlight offsets around separators and keyboard behavior.
- [x] Run focused native/behavior tests, pure self-checks, and inspect rendered results. Obtain independent review of the committed diff.
- [ ] Open the PR, require full CI on the latest integrated commit, squash-merge, verify the result, and clean up task-owned apps/worktrees where permitted.

## Execution evidence

- Base regression: `SidebarMicrointeractionTests.testPressInkFadesAfterReleaseAndPolicyCancelsTheTail` failed on the old code with release difference 0; the native loop and owned backend cleanup passed. Log: `/private/tmp/vane-sidebar-feedback-red-native.log`.
- Ruling: inspect folder hover visually instead of exposing the file-private row-hover environment solely for a snapshot test. The actual folder/disclosure and row ownership suites remain part of focused validation.
- The first focused implementation pass passed 64 tests and owned-backend cleanup. A pure self-check run also passed.
- Copy regression: the default SF Symbol replacement was not settled at 250ms (pixel difference 249 against its later settled rendering). Log: `/private/tmp/vane-copy-feedback-red.log`. A speed multiplier still left glyph motion at that deadline; captured frames confirmed the residual travel. The glyphs now crossfade directly over 120ms, and the confirmation dwell is 900ms. Logs: `/private/tmp/vane-sidebar-menu-speed-final.log`, `/private/tmp/vane-copy-feedback-diagnostic.log`.
- Ruling: use a controlled crossfade for Copy Link. Both SF glyphs keep stable nodes, begin the confirmation together, and finish within the same short feedback duration instead of depending on the system effect's internal phases.
- Final focused run: 77 tests passed, including the unchanged 250ms copy deadline, sidebar release sampling, native activation, hover/disclosure, folder locks, menu placement/typeahead, and policy identity. Owned fixture cleanup passed. Log: `/private/tmp/vane-sidebar-menu-validated.log`.
- The merged latest-main tree passed the same 77 checks and pure self-checks. After the neutral-ink follow-up, 77 checks passed again; the copy fixture now verifies visible grayscale ink against both native light and dark appearances. Logs: `/private/tmp/vane-sidebar-menu-integrated.log`, `/private/tmp/vane-sidebar-menu-neutral.log`.
- Native captures were inspected for press/release, cancelled motion, folder closed/hover/open states, and the menu highlight. The optional menu capture first failed because resizing its fixed-size hosting owner caused an asynchronous resize back to 100pt, correctly dismissing the menu. Resize diagnostics established that cause; a separate plain native owner now admits the exact visible menu before input and passes capture/cleanup. Logs: `/private/tmp/vane-menu-capture-admission.log`, `/private/tmp/vane-menu-capture-fixed.log`.
- Required CI exposed a shared native assertion failure on main `fd6265e` (run `41233638617`) and PR #563: the retained-sidebar regression reached the document end while Row 27 had visible height 0. Original failure evidence is preserved at `/private/tmp/vane-main-41233638617-failure.log`; passing unchanged local retries are not treated as a resolution.
- Three predetermined baseline local attempts passed, but an explicit admission probe failed: the original fixture sent every scroll gesture without `NSApp.run`, an active application, or its exact key window. Log: `/private/tmp/vane-folder-native-admission-red.log`. The fixture now owns/joins its AppKit loop, admits current scoped row population and exact native viewport geometry, and admits foreground ownership before each gesture. The original 160-event budget, 8ms intervals, 180ms tail, three end attempts, and all geometry assertions/tolerances remain unchanged.
- The repaired class and offscreen-readiness tests passed 9/9. Three predetermined focused local attempts then passed 22/22 each, including nearby profile persistence, reading queue capture, folder disclosure, and retained/offscreen fixtures; primary and cleanup status were 0 for every attempt. Logs: `/private/tmp/vane-folder-foreground-repair.log`, `/private/tmp/vane-folder-admitted-local-{1,2,3}.log`.
- A diagnostic branch adds only a workflow to the repaired app/test tree and runs three sequential focused attempts on macOS 26, preserving every original log and requiring selected-test completion and cleanup. Hosted preflight run: `41236616725`. Full required CI resumes only after this preflight passes. Main's strict `checks` protection and administrator enforcement remain enabled; all main CI runs must also finish before merge.

- Full PR CI `41237310379` caught a Space preview parity regression: 10 cases / 13 comparisons differed by exactly 78 channels. The unchanged feature-head capture in `41238992605` reproduced it with cleanup0 and localized every difference to 26 ellipsis pixels at x229–240/y16–18. Moving opacity inside the native Menu label let its extracted symbol remain painted while hidden. Original tolerance10 and all assertions remain intact.
- A provisional whole-Menu mask at `92216e7` passed three hosted focused attempts in `41239769848`: 54 selected cases each, 51 passed plus three existing motion-precondition skips, all 17 Space preview cases passed, cleanup0. This did not establish native focus or focus-ring correctness. Three temporary local QA probes failed admission before input because the SwiftUI Menu has no NSButton descendant; public in-process AX hit testing flattened to the host. Their exact sources, binary hashes, logs, screenshots and cleanup/exit checks are preserved under `/private/tmp/vane-space-options-*` and in the coordination status. Unavailable routes are not counted as passing.
- Final ruling follows the coordinator’s narrower accepted scope: remove the provisional mask and restore only Space options to main’s existing `.focused` then whole-Menu `.opacity` behavior, without an animation or identity reset on that native control. All other independently validated microinteractions remain. The entire native Menu block is byte-identical to main; proof is `/private/tmp/vane-space-options-main-parity-proof.json`. Temporary unsupported QA code is preserved separately and removed from the working tests; every committed regression assertion remains unchanged. Focused hosted validation must now cover this actual final source before any coordinated integration/full CI refresh.
