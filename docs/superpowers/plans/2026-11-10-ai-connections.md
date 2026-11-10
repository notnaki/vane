# AI connections implementation plan

> **For agentic workers:** Use superpowers:executing-plans; implement inline and obtain independent final review.

**Goal:** Add ChatGPT subscription sign-in, multiple saved AI connections, and independent Max feature routes.
**Architecture:** Codable connection/route preferences reference isolated Keychain items. ChatGPT uses public OAuth with validated identity and a dedicated Responses SSE transport; BrowserAI resolves each feature's route.
**Tech Stack:** Swift 6, SwiftUI, Foundation, Security, CryptoKit, Network; no new dependencies.
**Spec:** ../specs/2026-11-10-ai-connections-design.md (builder check: nothing important left).

## Global constraints

- Existing cloud connections and all summary defaults migrate without widening data sharing.
- Cloud requests are blocked in private windows; secrets never enter defaults or logs.
- Separate ChatGPT registrations/refreshes, explicit routing, no automatic billing fallback.
- Existing cancellation, validation, motion policy, and protected merge requirements apply.

## Review focus

- Switching/removing an editor while sign-in/test/refresh runs must not resurrect a removed connection.
- Equal email addresses must not merge distinct ChatGPT account/workspace registrations.
- Temporary auth failures must retain renewable credentials; terminal ones require reconnect.
- Incomplete/oversized SSE must never produce an accepted answer.
- A new cloud connection must not automatically receive page text.

### Task 1: Persist connections and routes

Files: new Sources/Vane/AIConnections.swift; Sources/Vane/CloudAI.swift; new Tests/AIConnectionsHarness.swift and scripts/check-ai-connections.sh.
Interfaces: AIConnection (stable UUID/provider/name/model/baseURL/registration/credential account); AIFeature; AIConnections.load(_:), save(_:), connection(for:), route(_:to:), remove(_:).
- [x] Add failing offline cases for legacy migration, repeated load, same-provider isolation, independent routes, removal and summary default.
- [x] Run the harness, implement the model, rerun to green and commit.

### Task 2: Authenticate and use ChatGPT

Files: new ChatGPTOAuth.swift, ChatGPTSession.swift, ChatGPTResponses.swift and offline harnesses/scripts.
Interfaces: OAuth Pending/Registration/Credentials; JWT validation; bounded loopback sign-in; serialized credential renewal; model listing; ChatGPTResponses.complete(_:prompt:isPrivate:using:) async throws -> String.
- [x] Add failing callback/state/client-ID and JWT claim/signature fixtures; implement and verify.
- [x] Add failing model/SSE/wire-format/private/terminal error fixtures; implement and verify.
- [x] Test rotating-token persistence, transient failures, sign-out and stale sign-in results; implement and verify.
- [x] Commit independently testable auth and transport.

### Task 3: Wire Max settings and feature calls

Files: AIProviderSettings.swift, BrowserAI.swift, SettingsWindow.swift, TidyTabs.swift, TidyTitles.swift, Previews.swift, PRIVACY.md, docs/INTEGRATIONS.md.
Interfaces: BrowserAI.ready(for:), unavailableReason(for:), per-feature request resolution, summarizeStream(_:sentences:isPrivate:).
- [x] Add failing routing/private/stale-response integration fixtures where practical.
- [x] Replace the single provider editor with saved connections and per-feature pickers; keep existing switches and motion policy.
- [x] Route each caller; preserve local summary defaults/grounding, pass private context, and discard changed configurations.
- [x] Update integration/privacy copy, run focused harnesses and Swift build/test; commit.

### Task 4: Review and delivery

- [x] Open/link PR with checks and offline/live-validation limits.
- [x] Obtain independent final diff review; fix actionable findings and rerun affected checks.
- [ ] Verify latest main integration, checks, approvals, and all main runs before squash-merge.
- [ ] Verify merge and safely clean task worktree/test apps according to project policy.

## Execution ledger

- Baseline: scripts/check-cloud-ai.sh passed (36 checks).
- Design: independent builder check returned “nothing important left”; user confirmed per-Max-feature routing.
- Ruling: Use this task's already-created T3 worktree and rename its branch to codex/chatgpt-signin-provider-routing; native handoff cannot create another worktree for an already attached thread.
- Ruling: Implement inline under the user's request and repository default implementation workflow; no additional design/execution permission round is needed.

- Implementation: connection migration/isolation, OAuth PKCE/JWT validation, Responses SSE, rotating-token coordination, editor and feature routes implemented.
- Offline validation: cloud transport, connection migration, real BrowserAI dispatcher with isolated I/O boundaries, OAuth/JWT/SSE, and production refresh-order fixtures pass. Mutation checks reproduce the stale-upload/local-result defects and pass with the fixes.
- Independent review found six lifecycle/documentation issues; fixed request-context cancellation, sign-out admission, metadata-before-refresh ordering, stale local answers, operation generations, and erasure copy.
- Native validation: initial full run interrupted for another task's Resize capture (primary 1 / cleanup 0; 229 owned backends retired). Preserved /tmp/vane-ai-native-tests.log, including BrowserWindowTitleTests.testBlankAndEmptyTitlesUseGenericWindowTitleWithoutExposingURL failure. Investigation: its fixture admitted WebKit isLoading=false before Vane's didFinish, which republishes the title after the test's synthetic blank-title mutation. Added the !tab.loading prerequisite without changing assertions/deadlines; three fixed focused runs are being retained as preflight logs.
- Ruling: repair the native title fixture prerequisite as part of validation — an unchanged passing retry would not explain the original assertion failure.

- Fresh independent review approved implementation commit e2c1a3e67db51a24396839063bb0de2cb834f92d with no actionable findings and independently reran all five offline harnesses. PR: https://github.com/notnaki/vane/pull/633. Required CI and merge remain pending.
- The second full local run was stopped for the next requested Resize capture (primary 1 / cleanup 0); exact host retirement verified at 18:58:03 +03. Keep local desktop input clear; full native coverage will run in required CI.
- Title preflight: three fixed runs (/tmp/vane-ai-title-preflight-{2,3,4}.log), each 8 cases passed plus verified retirement.
- CI build follow-up: job 129975899494 in run 42857841675 crashed in Swift 6.3.3 IRGen while generating the isolated String setter reabstraction thunk in AIProviderSettings. Local Swift 6.4 had compiled it. A reduced Binding case confirms the direct method reference generates isolation/reabstraction wrappers, while an explicit setter closure generates none. Wrap changeEndpoint in that closure, preserve its credential-removal behavior, and preflight a fresh native app/test build against macOS SDK 26.5 before pushing. Exact Swift 6.3.3 verification remains with CI.
