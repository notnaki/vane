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

- [ ] Write tests for cutoff inclusion, old/future eviction, capacity, private-event rejection, snapshot stability, default log exclusion, opt-in filtering, and URL decoding/oversize fallback.
- [ ] Run the focused tests and observe missing APIs fail.
- [ ] Implement `DiagnosticEvent`, `DiagnosticLog`, `IssueReportDraft`, and `IssueReportHandoff` with an injected clock in tests and a size-bounded URL decision.
- [ ] Run focused tests, then commit the model and tests.

### Task 2: Native report window and instrumentation

Files: create `Sources/Vane/IssueReportWindow.swift`, `Tests/VaneTests/IssueReportWindowTests.swift`; modify `Menu.swift`, `Palette.swift`, `Engine.swift`, `main.swift`, `README.md`.

- [ ] Add native tests proving shared presentation preserves a visible draft, close/reopen clears consent, and a real navigation failure records only a numeric code while private activity is absent.
- [ ] Implement title/description entry, optional logs and time-window picker, exact preview, copy/save, and GitHub draft action with explicit oversized fallback and open/save errors.
- [ ] Wire Help and the existing palette report action. Instrument launch and accepted public navigation start/commit/finish/failure/process-termination callbacks.
- [ ] Run the focused native regressions through `scripts/run-native-tests.py`, build and pure selfchecks, update documentation, and commit.

### Task 3: Review and integrate

- [ ] Inspect the final diff and obtain independent review of the current head; repair actionable findings and validate them.
- [ ] Push, open and link a PR, satisfy required CI and review on the latest integration tree.
- [ ] Recheck separate main CI, squash-merge, verify preservation, clean up task-owned processes/worktree, and report links and verification.
