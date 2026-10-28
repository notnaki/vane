# CI reliability implementation plan

> **For agentic workers:** Use superpowers:executing-plans for inline implementation, then obtain independent review of the current PR diff.

**Goal:** Make required CI validate the actual integration and replace the identified native-fixture timing assumptions with explicit prerequisites.

**Architecture:** Keep existing product assertions and fixture deadlines. Establish the real AppKit/document context before browser notifications; sample the arriving profile's visible sidebar instead of an arbitrary retained scroll view. Enforce current-main CI through GitHub branch protection. Known worker-UA behavior remains a separately reported unresolved product limitation.

**Tech stack:** Swift/XCTest, AppKit/WebKit, Python workflow fixtures, GitHub Actions.

**Spec:** User request in this chat: CI must not depend on luck. The user separately approved strict required `checks` protection for main, including administrators.

## Constraints and evidence

- No retry-until-green, assertion weakening, extra skips, or broader known-limitation exclusions.
- #545's tested merge used main 5588942; #541 landed before #545, adding 17 files' changes to its final tree.
- Main f9d16a4 failed the reused-password-step notification and cached-profile sidebar presentation. Both fixture cleanups passed.
- The password notification fixture moves its window offscreen and runs without an owned NSApplication loop. Its tested mutation schedules a JavaScript timer.
- BrowserWindowHost retains hidden profile roots. The sidebar test recursively selects the first scroll view without checking visibility.
- Worker-UA wrong values have independent signed-app reproductions in #513. A passing sample does not resolve that bug.

## Task 1: Reproduce and repair native fixture assumptions

- [x] Run the original two failing tests on a clean current-main build and retain their results.
- [x] Add a fixture-context regression requiring the document notification test to own a running AppKit loop and an attached visible document; observe RED before changing fixture setup.
- [x] Repair the notification fixture's event-loop/window lifecycle, preserving the tested mutation, original five-second outcome deadline and actual received message assertions.
- [x] Demonstrate that selecting the first scroll view can choose a hidden parked root; select only the visible arriving profile's scroll view and prove its ownership before sampling.
- [x] Establish initial native presentation readiness before the action under test. Preserve early-versus-settled geometry assertions; do not wait for the tested result before taking the early sample.
- [x] Run focused native coverage and a predetermined repeat cohort; every execution must pass and retire its owned fixtures.

## Task 2: Enforce the integration gate

- [x] Read existing GitHub rules/protection and preserve unrelated settings.
- [x] Require GitHub Actions `checks`, strict current-main validation and administrator enforcement on main; verify the saved settings.
- [x] Document failures, reruns, current-base integration and advisory results accurately in AGENTS.md / docs/DEVELOPMENT.md.
- [x] Run relevant workflow fixtures and diff checks.

## Task 3: Review, CI and integration

- [ ] Open a focused codex/ PR; obtain independent current-diff review and address actionable findings.
- [ ] Require current-base CI; investigate any remaining failures without rerunning them into a passing claim.
- [ ] Squash-merge only after the reviewed current integration passes, then verify actual-main results.
- [ ] Verify task-owned native test processes have exited and archive this worktree after preserving the merged work.

## Validation record

- Original two tests passed in one local baseline sample; this did not erase the hosted failures.
- Both new fixture-contract regressions failed against the old setup: no owned AppKit/foreground context and selection of the hidden parked scroll view.
- Five targeted tests pass after repair, with primary/cleanup status 0.
- Negative control: removing the product's profile presentation snap fails both original geometry assertions (13 versus 8; 665 versus 670). Restored the product source exactly afterward.
- Negative control: omitting the product's mutation-ready notification fails the original five-second password-step wait, with the app running and document on screen. Restored product source exactly afterward.
- Workflow validation: 2,078 gate cases, nine shard fixtures and seven change-scope fixtures pass.
- GitHub protection saved and read back: strict=true, required GitHub Actions `checks` (app 15368), enforce_admins=true, pull requests required, no additional human approval count.
- Independent read-only review of the implementation: no actionable findings. All 60 related native tests passed; all three predetermined fresh five-test runs passed (15 executions). Every run verified primary/cleanup status 0. Exact-commit review and hosted CI remain pending.

Local macOS 27 validation does not replace macOS 26 CI. Known worker-UA issue #513 remains unresolved; no product behavior or limitation assertions changed in this task.
