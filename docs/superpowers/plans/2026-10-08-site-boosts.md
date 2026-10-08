# Site Boosts Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the current session. The user requested immediate execution after approving the design and receiving the spec.

**Goal:** Add live per-site fonts/colors, Zap hiding, CSS, and optional scripts.
**Architecture:** A Codable Boost and profile-scoped store feed a stable isolated-world WebKit runtime. Native messages identify each document; live updates and page-world scripts check that identity before executing. A native panel edits the originating tab without blocking page interaction.
**Tech Stack:** Swift 6, SwiftUI, AppKit, public WebKit APIs, XCTest.
**Spec:** docs/superpowers/specs/2026-10-08-site-boosts-design.md

## Global Constraints

- macOS 26 or later; no additional product dependencies.
- Exact HTTP(S) origin matching; private values stay per-tab in memory.
- Preserve all existing scripts, handlers, and blocking rules.
- Respect Reduce Motion and Battery Saver.

## Review Focus

- Old messages after navigation must not update or script a new document.
- Editing disabled Boosts must not inadvertently enable JavaScript.
- Dynamic content should obey hidden-element CSS without repeated DOM scans.
- Private tabs and distinct profiles must never share saved scripts.
- Closing an editor or tab must remove Zap listeners and overlays.

## Tasks

- [x] 1. Write origin, model, persistence, private-lifetime, and Site Controls tests. Run `swift test --filter SiteBoostTests` to confirm missing-feature failures. Implement `SiteBoosts.swift` and re-run.
- [x] 2. Add WKWebView tests for styling/reset, dynamic elements, navigation isolation, selector picking/undo, and opt-in script errors. Implement `SiteBoostScripts.swift`, Engine controller/message/lifecycle hooks, and re-run the focused tests.
- [x] 3. Build `SiteBoostEditor.swift`: native panel, live controls, presets, CSS/JS tabs, Zap/undo/reset, and script feedback. Wire Site Controls and profile deletion; document the flow in README.
- [x] 4. Run debug build, relevant XCTest and pure selfcheck. Inspect the native editor and Zap with a tracked task-owned fixture; close it afterward. Commit and open a PR.
- [ ] 5. Independently review the current PR diff; fix findings and revalidate. Wait for required CI/approvals, squash-merge, verify the merge, and sync main when safe.

## Execution ledger

- Design spec committed as 188fc81. Working tree was clean on codex/site-boosts.
- Ruling: Execute inline without another approval round; the user explicitly said “do it dude.”
- Ruling: Use stable injected runtime and native document messages instead of rebuilding controller scripts; public WebKit has no individual user-script removal API, and this preserves every existing script.

- Ruling: Use a constructed stylesheet and directly compiled page-world scripts; a restrictive-CSP fixture proved style elements and eval() were blocked. This keeps customization working without altering the site policy.

- Verification: 11 focused tests passed, including restrictive CSP; full XCTest passed 523 tests with one existing skip and zero failures. Debug build and pure selfcheck passed. Native editor flow is covered by a window fixture; GUI automation resolved the duplicate app identity to another Vane instance, so no UI actions were sent to it.

- Review 3fa17192: fixed cancelled-navigation document retention, whole-iframe Zap hit testing, and per-host Boost cleanup during Clear Site Data. Three regression scenarios failed before these fixes.

- Review fixes verified: integrated Boost/autofill/blocker run passed 35 tests; pure selfcheck passed. Persistent and private host reset, sibling-tab updates, iframe selection, and cancellation are covered.
