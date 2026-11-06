# Address pill reference motion

**Goal:** Match the supplied 6.375-second address-pill recording.

**Architecture:** Keep one pill across optional-tab changes. Observe the selected tab without replacing the pill's focus or hover state. Crossfade the host and slide/fade the search prompt over 0.18 seconds; fade page actions on hover or keyboard focus while keeping their layout slots stable.

**Tech stack:** SwiftUI, Combine, AppKit, XCTest.

**Spec:** User-supplied `Screen Recording 2026-11-06 at 21.40.49.mov` (2026-11-06).

## Constraints

- Reduce Motion and Battery Saver apply state changes immediately.
- Preserve compact and Little Vane layouts, pinned extensions, page actions, and accessibility actions.
- Preserve the original checkout's unrelated edits.

## Review focus

Optional-tab replacement must retain focus; navigation must update observed page metadata; hidden controls must remain keyboard reachable; rapid reversals must settle at the latest state; policy changes must cancel decorative motion.

## Implementation

- [x] Add a rendered regression demonstrating resting page actions are hidden and keyboard focus reveals them.
- [x] Keep the pill mounted; add the host/search and hover/focus transitions using shared motion tokens.
- [x] Verify tab replacement, live address updates, motion-policy behavior, and action activation in focused native fixtures.
- [x] Run focused tests, build, pure selfchecks, and diff checks.
- [ ] Obtain independent review, resolve findings, and complete the repository PR/merge workflow.
