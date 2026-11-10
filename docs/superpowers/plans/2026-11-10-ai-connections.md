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
- [ ] Add failing offline cases for legacy migration, repeated load, same-provider isolation, independent routes, removal and summary default.
- [ ] Run the harness, implement the model, rerun to green and commit.

### Task 2: Authenticate and use ChatGPT

Files: new ChatGPTOAuth.swift, ChatGPTSession.swift, ChatGPTResponses.swift and offline harnesses/scripts.
Interfaces: OAuth Pending/Registration/Credentials; JWT validation; bounded loopback sign-in; serialized credential renewal; model listing; ChatGPTResponses.complete(_:prompt:isPrivate:using:) async throws -> String.
- [ ] Add failing callback/state/client-ID and JWT claim/signature fixtures; implement and verify.
- [ ] Add failing model/SSE/wire-format/private/terminal error fixtures; implement and verify.
- [ ] Test rotating-token persistence, transient failures, sign-out and stale sign-in results; implement and verify.
- [ ] Commit independently testable auth and transport.

### Task 3: Wire Max settings and feature calls

Files: AIProviderSettings.swift, BrowserAI.swift, SettingsWindow.swift, TidyTabs.swift, TidyTitles.swift, Previews.swift, PRIVACY.md, docs/INTEGRATIONS.md.
Interfaces: BrowserAI.ready(for:), unavailableReason(for:), per-feature request resolution, summarizeStream(_:sentences:isPrivate:).
- [ ] Add failing routing/private/stale-response integration fixtures where practical.
- [ ] Replace the single provider editor with saved connections and per-feature pickers; keep existing switches and motion policy.
- [ ] Route each caller; preserve local summary defaults/grounding, pass private context, and discard changed configurations.
- [ ] Update integration/privacy copy, run focused harnesses and Swift build/test; commit.

### Task 4: Review and delivery

- [ ] Open/link PR with checks and offline/live-validation limits.
- [ ] Obtain independent final diff review; fix actionable findings and rerun affected checks.
- [ ] Verify latest main integration, checks, approvals, and all main runs before squash-merge.
- [ ] Verify merge and safely clean task worktree/test apps according to project policy.

## Execution ledger

- Baseline: scripts/check-cloud-ai.sh passed (36 checks).
- Design: independent builder check returned “nothing important left”; user confirmed per-Max-feature routing.
- Ruling: Use this task's already-created T3 worktree and rename its branch to codex/chatgpt-signin-provider-routing; native handoff cannot create another worktree for an already attached thread.
- Ruling: Implement inline under the user's request and repository default implementation workflow; no additional design/execution permission round is needed.
