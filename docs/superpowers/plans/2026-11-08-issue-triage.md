# Issue triage implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in this session. The user requested “just build it”; proceed through validation, independent review, and the repository PR workflow.

**Goal:** Make bug reports useful with an optional, reviewable snapshot of recent diagnostics and a GitHub issue draft.

**Architecture:** A bounded, memory-only event buffer accepts typed events and numeric error codes, never arbitrary page data. A report model freezes events when opened, filters a selected time window, renders Markdown, and prepares a size-checked GitHub issue URL. A native SwiftUI/AppKit secondary window shares this model between Help and the command bar.

**Tech stack:** Swift 6, Foundation, AppKit, SwiftUI; no dependencies or backend.

**Spec:** User request and clarification in this conversation: optional logs, optional GitHub issue creation, “just build it.” Defaults below are implementation decisions.

## Constraints and review focus

- Logs are off by default in every new draft. Never upload, persist, or copy a report without an explicit user action.
- Retain at most 2,000 events for five minutes. Capture only fixed event names and numeric error codes; exclude private tabs entirely.
- Freeze the snapshot when opening a draft, with last 30, 60 (default), or 300 seconds selectable. Explain bounded retention and snapshot time.
- Include version/build/macOS metadata and the user's description. Show the exact Markdown before sharing; allow copy/save without GitHub.
- Prefill logs inline in a GitHub issue draft. If the encoded URL exceeds 7,500 bytes, explicitly offer Copy Report & Open GitHub; never silently drop logs or truncate prose.
- Honor Reduce Motion and Battery Saver using existing Look tokens and secondary window styles. Preserve a visible draft on repeated presentation, discard it on close.
- Test time boundaries, capacity eviction, privacy, frozen snapshots, optional logs, Unicode/Markdown preservation, oversized handoff, and failure behavior. Native tests must own their fixture and avoid posting real issues.

## Tasks

### Task 1: Diagnostic buffer and report model

Files: create `Sources/Vane/IssueReport.swift`, `Tests/VaneTests/IssueReportTests.swift`.

- [x] Write tests for cutoff inclusion, old/future eviction, capacity, private-event rejection, snapshot stability, default log exclusion, opt-in filtering, and URL decoding/oversize fallback.
- [x] Run the focused tests and observe missing APIs fail.
- [x] Implement `DiagnosticEvent`, `DiagnosticLog`, `IssueReportDraft`, and `IssueReportHandoff` with an injected clock in tests and a size-bounded URL decision.
- [x] Run focused tests, then commit the model and tests.

### Task 2: Native report window and instrumentation

Files: create `Sources/Vane/IssueReportWindow.swift`, `Tests/VaneTests/IssueReportWindowTests.swift`; modify `Menu.swift`, `Palette.swift`, `Engine.swift`, `main.swift`, `README.md`.

- [x] Add native tests proving shared presentation preserves a visible draft, close/reopen clears consent, and a real navigation failure records only a numeric code while private activity is absent.
- [x] Implement title/description entry, optional logs and time-window picker, exact preview, copy/save, and GitHub draft action with explicit oversized fallback and open/save errors.
- [x] Wire Help and the existing palette report action. Instrument launch and accepted public navigation start/commit/finish/failure/process-termination callbacks.
- [x] Run the focused native regressions through `scripts/run-native-tests.py`, build and pure selfchecks, update documentation, and commit.

### Task 3: Review and integrate

- [x] Inspect the final diff and obtain independent review of the current head; repair actionable findings and validate them.
- [ ] Push, open and link a PR, satisfy required CI and review on the latest integration tree.
- [ ] Recheck separate main CI, squash-merge, verify preservation, clean up task-owned processes/worktree, and report links and verification.

## Verification record

- Baseline: `swift build -c debug --build-tests --disable-index-store` passed.
- Model RED: missing diagnostic/report APIs; GREEN: six tests passed.
- Native RED: missing report window/session APIs. Added edge cases then observed oversized combining-mark URL and missing window minimum fail; fixed URL fallback and explicit content minimum.
- `scripts/run-native-tests.py --disable-index-store --jobs 1 --filter IssueReport`: 14 tests passed; exact fixture cleanup status 0.
- `vane selfcheck --pure`: 3,680 assertions passed. Light default-size and dark minimum-size report captures inspected.
- Independent review found one P2: oversized title text could be lost. Full summary is now part of previewed/copied/saved Markdown; regression observed RED then GREEN, including a combining-mark title.
- After the review fix, report/navigation/palette coverage: 59 tests passed, primary status 0, exact cleanup status 0.
- Additional lifecycle regression reproduced replacement of a hidden draft. Reusing the retained controller until close now preserves hidden/minimized drafts; targeted validation recorded in the PR.
- Hidden-draft fix: focused report tests 15/15 passed, primary/cleanup status 0; final pure selfchecks passed. No task-launched standalone Vane app was run.

## CI fixture repair

Run 42472088513 failed only the real-navigation diagnostic fixture in native shard 3; the aggregate check propagated that failure. The fixture used an unattached WebView, no owned AppKit loop, and reserved port 1. Explicit local prerequisite assertions reproduced the missing loop/document state. Repair admits an owned loop and exact foreground document, proves a successful loopback load, then waits for terminal listener cancellation on an ephemeral port before testing connection refusal. The original 10-second outcome deadline and privacy assertions remain; the numeric assertion now verifies cannot-connect-to-host specifically. Tab/window/server cleanup precedes loop join, and the original activation policy is restored.

The isolated repaired case passes with primary/cleanup status 0. Three fresh-process related-suite preflights are required before pushing for full CI; every attempt is retained and results recorded in the PR. An initial preflight selection failed before the repaired case because ImportWorkerTests used Windows.current before NSApplication existed; including BrowserWindowTitleTests retains the same earlier AppKit initialization present in the original CI shard. A separate local setup attempt exhausted its outer budget rebuilding before test execution; compilation and native execution were subsequently separated. Neither setup failure is treated as a passing retry of the original native assertion.
