# Website authentication popups implementation plan

> Execute inline using the debugging, TDD, and verification skills; independent review follows on the PR.

**Goal:** Give website dialog popups a temporary window distinct from Little Vane, preserving WebKit relationships and ordinary new-tab links.

**Architecture:** Keep `Tab(popup:)` and WebKit's related-page configuration. Replace the `.little` website placement with `.window`, hosted by a retained AppKit window controller outside `TabStore.all`. Use native close controls and a read-only origin/title; defer script-close teardown beyond WebKit's callback. Nested ordinary links route through the originating store where available.

**Spec:** User request in this chat; AGENTS.md governs validation, review, squash merge, and task-owned app cleanup.

**Constraints:** macOS 26+, preserve profile/private data store; no sidebar/session entry, Little Vane branding, or Open in Space action. No URL heuristics for authentication providers. Keep existing tab placement/focus rules.

- [x] Inspect current routing and checks; run NavigationWebKitTests as baseline.
- [x] Add failing real popup-window tests using existing `.little` placement: no floating store, native temporary chrome, manual close leaves opener intact.
- [x] Implement `.window` and a dedicated controller, preserve WebKit configuration, route nested windows and links, remove Little Vane's popup constructor. Update pure checks and comments.
- [x] Extend real HTTP/WebKit fixtures for blank/document.write, opener/postMessage, redirect, script close, profile/private cookies, nested popup and ordinary target=_blank behavior. Test invalid/oversized window sizes.
- [x] Run focused popup/navigation/link tests and pure checks; build the signed test app if real-site inspection is available. Record Reddit Google flow limits honestly.
- [ ] Push a focused PR; obtain independent current-diff review, address findings and revalidate. Wait for required CI and mergeability, squash merge, verify commit, clean up task-owned app processes.

Review focus: close callback lifetime; private data-store identity and profile isolation; redirect origin display; nested popup ownership after opener closes; background focus and ordinary `_blank` routing.

Validation record: 72 focused tests passed on macOS 27 / Swift 6.4, including native
password overlay rendering, chooser keyboard/pointer dismissal and Option text entry.
The original regression failed against Little Vane routing before implementation;
review regressions also failed before fixes. `selfcheck --pure` passed. A signed debug
bundle built successfully. Reddit/Google acceptance remains unverified: the isolated
signed app timed out in native UI automation; its owned process was terminated and
verified exited. Independent review identified password UI and input shortcut gaps;
both are fixed and the updated commit must be reviewed before merge.
