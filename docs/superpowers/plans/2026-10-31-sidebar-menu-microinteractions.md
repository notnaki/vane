# Sidebar and menu microinteractions

**Goal:** Extend Vane's everyday feedback across tabs, folders, favourites, the Space header, and custom menus.

**Architecture:** Keep existing native event monitors and activation paths. Animate decoration only; keep row geometry, editors, hit targets, and focus owners stable. Use existing SwiftUI timing and motion policies, without dependencies or continuous effects.

**Spec:** User request to add more microinteractions, especially tabs, folders, and menus; repository AGENTS.md motion and integration requirements.

## Motion thesis

- Feedback: immediate sidebar press ink followed by a short release fade, shared by tab/folder rows and favourite tiles.
- Continuity: the closed folder's existing flap anticipates opening slightly on hover, then continues into the normal disclosure shape. Locked folders and drag previews retain their actual state.
- Menus: one pointer highlight moves between items; keyboard navigation stays immediate. Entrance originates at the trigger and finishes immediately if motion policy changes.
- Space header: short fades connect its icon, disclosure, options, and hover background.
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
