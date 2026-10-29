# Native-Messaging Error Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the approved error-only native API mode repair Bitwarden's popup starvation while permanently blocking every native-app connection.

**Architecture:** Keep existing installation/access approval unchanged. Add a separately reviewed, versioned per-record compatibility choice; apply it before WebKit context loading, and reject both native delegate paths through a cancellable100ms denial policy. Reuse accepted-code storage and its rollback/lifetime rules rather than introduce a host registry or transport.

**Tech Stack:** Swift, AppKit/SwiftUI, public macOS26+ WebKit WebExtensions APIs, XCTest, existing native runner.

**Spec:** `docs/superpowers/specs/2026-10-28-native-messaging-error-compatibility-design.md` (explicitly user-approved).

## Global Constraints

- Existing installations retain their current hidden-API/denied-permission contract until a user explicitly reviews this separate compatibility mode.
- New installation approval alone must not silently opt in.
- Every application identifier and payload receives an unavailable error; never invoke, connect, forward to, or read data from a native application.
- Do not return successful fake `sleep` results or usable ports.
- Defer denial replies by a defined100ms policy to prevent sequential retry churn.
- Never inspect or log message payloads. No private SPI, injected browser API shim, engine fork, or vendor resource modification.
- Preserve original welcome deadlines, other permissions, profiles, stores, controller/runtime identity and UA assertions. Issue513 remains open.
- Coordinate WindowServer/build ownership with the compact-window implementation; this plan does not change its UI/container design or CI classifier.
- The user selected implementation already. Root executes inline with independent review; no new execution-method approval is needed.

## Review Focus

- Old/future mode metadata and removing then re-adding `nativeMessaging` must not silently opt in: Task1 tests.
- Approval delivered after installation/profile replacement or a concurrent discovery must not change another accepted installation: Task3 tests.
- Disable/revoke/unload during a pending error must release work and never deliver success: Task2/3 tests.
- Failed persistence or context activation must retain the previous accepted mode/code/disabled state: Task3 tests.
- Signed Safari app sources must never reach WebKit's automatic `NSExtension` fallback, including port requests: Task2/5 tests.

---

## File structure and existing seams

- New `Sources/Vane/ExtensionNativeMessagingErrors.swift`: versioned error-only policy and cancellable denial scheduling, with no host discovery/transport.
- `Sources/Vane/ExtensionCodeStore.swift`: optional mode-version field on `Record`; keep its existing atomic `save` commit point.
- `Sources/Vane/Extensions.swift`: conditional `makeContext`, all three context creation paths, permanent public delegates, scoped management transaction, update/restore/lifetime integration, `Entry` diagnostics.
- `Sources/Vane/ExtensionConsent.swift`: a separate native-error review model/prompt; do not change the meaning of existing `Review -> Bool` callbacks.
- `Sources/Vane/ExtensionManagement.swift`: explicit review/revoke controls in the existing `compatibility` section.
- Extend `ExtensionCodeStoreTests` and `ExtensionConsentTests`; new `ExtensionNativeMessagingErrorTests.swift` for policy/real SDK integration.
- Update `docs/DEVELOPMENT.md` only for the final contract/validation. Preserve unrelated compact-window/CI work and stage files explicitly.

### Task1: Backward-compatible versioned approval

**Files:** `ExtensionNativeMessagingErrors.swift`, `ExtensionCodeStore.swift`, `Tests/VaneTests/ExtensionCodeStoreTests.swift`.

**Interfaces:**
- Add `Record.nativeMessagingErrorCompatibilityVersion: Int? = nil`; only exact value1 means error-only approval. This field must never be reused as native-host authorization.
- Add `ExtensionNativeMessagingErrors.currentVersion = 1` and `isApproved(version: Int?, required: ExtensionAccess, optional: ExtensionAccess) -> Bool`. Require declared `nativeMessaging` in required or optional access; nil/unknown versions are off.
- Add `retainedVersion(from old: Record?, for required: ExtensionAccess, optional: ExtensionAccess) -> Int?`; preserve1 only for an existing accepted identity and still-declared permission. Existing source identity/signature checks remain authoritative.

- [x] Write `testNativeErrorModeOldAndUnknownVersionsStayOff`, `testNativeErrorModeRoundTripsOnlyWithinItsProfile`, and `testRemovingThenReaddingNativePermissionRequiresNewApproval`. Assert nil and future2 cannot expose APIs, profile B does not inherit A, and removing the declaration clears the stored choice.
- [x] Run `python3 scripts/run-native-tests.py --build-system native --jobs 1 --filter 'ExtensionCodeStoreTests'`; retain the expected RED against the missing field/policy.
- [x] Implement these optional metadata/policy interfaces. Do not add `nativeMessaging` to `integratedCapabilities` or remove it from the ordinary unsupported-permission filter.
- [x] Run that focused command and `git diff --check`; expect all selected tests passed with primary0/cleanup0.
- [x] Commit only the model/policy/test changes: `feat: persist separately approved native error compatibility`.


Task1 evidence: `/tmp/vane-native-error-record-red.log` shows accepted metadata dropping approval; `/tmp/vane-native-error-policy-red.log` shows three missing-policy assertions. Native-backend GREEN `/tmp/vane-native-error-policy-green.log`:18 tests passed, primary0/cleanup0.

### Task2: Permanent public denial and defined backpressure

**Files:** `ExtensionNativeMessagingErrors.swift`, `Extensions.swift`, new `Tests/VaneTests/ExtensionNativeMessagingErrorTests.swift`.

**Interfaces:**
- `@MainActor final class ExtensionNativeMessagingDenial` with `init(sleep: @escaping @Sendable (Duration) async throws -> Void = ...)`, `wait(contextID: ObjectIdentifier) async throws`, `cancel(contextID: ObjectIdentifier)`, and `cancelAll()`. Default delay is exactly `.milliseconds(100)`; retain only context IDs/cancellable delay tasks, never payloads/ports/app identifiers.
- Permanent host method `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:) async throws -> Any?` waits then throws an unavailable `NSError`, never returns a reply.
- Permanent host method `webExtensionController(_:connectUsing:for:completionHandler:)` uses the SDK's completion-handler signature and completes with an unavailable error after the same policy; the SDK closes its genuine port.
- Fixed error text: `Native messaging hosts are unavailable in Vane.` Use a dedicated error domain/code; cancellation may also terminate with an error, never success.

```swift
func webExtensionController(_ controller: WKWebExtensionController,
    sendMessage message: Any, toApplicationWithIdentifier application: String?,
    for context: WKWebExtensionContext) async throws -> Any?
func webExtensionController(_ controller: WKWebExtensionController,
    connectUsing port: WKWebExtension.MessagePort, for context: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void)
```

- [x] Write controlled-sleeper policy tests: no completion before release, completion after the100ms policy, cancellation removes pending work, context A cancellation leaves B independent, no payload reaches logging/storage, and no request data remains retained after completion/cancellation. Avoid elapsed-time equality tests.
- [x] Write real SDK tests using an isolated synthetic declared-native extension/context. Verify both Objective-C selectors respond before load; callback calls observe `runtime.lastError`, Promise calls reject, ports receive `onDisconnect` with an error and no messages. An app identifier that would otherwise select Safari fallback still must reach these denial methods.
- [x] Run `python3 scripts/run-native-tests.py --build-system native --jobs 1 --filter 'ExtensionNativeMessagingErrorTests'`; retain RED for absent delegates/policy.
- [x] Implement the policy/delegates. Always provide both selectors, including for unapproved contexts, to prevent automatic `NSExtension` fallback. Forward neither method and create no native transport/provider. Public selector names: `webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:` and `webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:`.
- [x] Cancel scoped work in existing `deactivate(_:)`, removal and host invalidation/profile-forget paths, including candidate-context cleanup. Keep the SDK error completion bounded and exactly once.
- [x] Run the focused tests; expect all pass, primary0/cleanup0, owned backends absent. Commit the independently closed denial boundary.


Task2 evidence: six native policy/SDK tests passed, primary0/cleanup0, in `vane-native-error-denial-green3.log`. Public selectors, callback error/no reply, Promise rejection, port disconnect/no messages, exact request routing, cancellation and32-per-context/128-total bounds are covered. Prior SDK assertions and diagnostic logs are preserved: absent `runtime.lastError` is actual Safari null (typeobject/nulltrue/messagenone), so the corrected empty-error assertion accepts null/undefined after callback dispatch; no native policy was relaxed. Signed-app acceptance remains Task5.

### Task3: Atomic explicit opt-in, revocation, restore and update

**Files:** `Extensions.swift`, `ExtensionConsent.swift`, `ExtensionConsentTests.swift`, `ExtensionNativeMessagingErrorTests.swift`.

**Interfaces:**
- Add `ExtensionConsent.NativeMessagingErrorReview { let name: String }`, `makeNativeMessagingErrorPrompt(_:) -> NSAlert`, and `askNativeMessagingErrors(_:) -> Bool`. Existing `ExtensionConsent.Review` and every old installation `review` closure retain their current meaning.
- Add `ExtensionHost.setNativeMessagingErrorCompatibility(_ enabled: Bool, for path: String, review: @MainActor (ExtensionConsent.NativeMessagingErrorReview) -> Bool = ExtensionConsent.askNativeMessagingErrors) async throws -> Bool`. `false` means refusal; errors preserve the previous accepted state. Revocation needs no access-expanding consent.
- Extend private `makeContext(_:identity:runtimeID:nativeMessagingErrorCompatibilityVersion:)` with a default nil final argument. For approved declared-native contexts only, subtract the two native API names from `unsupportedAPIs` and grant nativeMessaging before `controller.load`. Assert both denial selectors first; all other grants follow the current code unchanged.
- Include `nativeMessagingErrorCompatibilityVersion` in `InstallationGeneration` so discovery cannot overwrite a concurrent mode change on a disabled extension.

Factory signature: `private func makeContext(_ ext: WKWebExtension, identity: String, runtimeID: String? = nil, nativeMessagingErrorCompatibilityVersion: Int? = nil) throws -> WKWebExtensionContext`. It throws before exposing either native API if the controller is not bound to the permanent denial delegate or either public denial selector is absent; this is a fail-closed implementation refinement.

- [x] Add tests for old ordinary `review: { _ in true }` installs staying off; explicit refusal leaving context/record identical; approved callback seeing the correct extension/profile; optional-declared native permission; unrequested native permission remaining denied; unknown version staying off.
- [x] Add transaction tests: enable and revoke across host forget/restart; disabled extension remains disabled; save failure and background activation failure restore the prior record/context/mode; removing/replacing an install or invalidating a profile during modal consent prevents adoption. Exercise both prior off and prior on rollback states and stale discovery generations. Snapshot non-native required/runtime permission decisions around the transition and verify they follow existing reload rules, with no additional grants or cross-profile inheritance.
- [x] Run `python3 scripts/run-native-tests.py --build-system native --jobs 1 --filter 'ExtensionConsentTests|ExtensionNativeMessagingErrorTests'`; preserve RED.
- [x] Implement the management method using the existing `operations[path]` token, `metadataFailure`, profile guard and accepted `records[path]`. Ask before mutation, recheck lifetime/identity after the modal, create a revised record/context, atomically save only after activation succeeds, then expose it synchronously. On failure unload the candidate and recover the old accepted context/disabled state. A disabled record changes metadata only.
- [x] Pass the accepted mode through loose-folder/store `loadCandidate`, signed-app `loadSafariCandidate`, and `context(for:record...)` restore/recovery. Fresh installs start nil; updates use Task1 retention and clear approval when native permission is removed. Do not silently opt in through `integratedCapabilities`, `restoreAccepted` or normal runtime permission prompts.
- [x] Run the focused tests plus `ExtensionCompatibilityTests|SafariAppExtensionMetadataTests`; expect all pass and scoped cleanup0. Commit transaction/context integration.

Task3 validation: focused native execution first passed15 cases, then17 with real SDK background-creation cancellation and caller cancellation controls, both primary0/cleanup0 and both exact native hosts exited per run. `native-error-mode/task3-cancellation-native/` retains the final17-case sources, ownership and raw output. Independent snapshot review found only the optional-native temporary-revoke bug subsequently repaired below. The preserved closed-boundary RED selected9 tests; two fixture mistakes were corrected explicitly: public unsupported API names include `browser.`, and re-encoding Codable Sets is not a stable byte comparison, so invariance compares actual accepted index bytes. No acceptance assertions were removed. Stale signed-discovery admission and production signed-package acceptance remain pending. No issue484 resolution is claimed yet.

Signed-discovery follow-up: `SafariAppExtensionTests.testDisabledModeChangeInvalidatesEarlierVerifiedSafariDiscovery` pauses after genuine signature verification using a default-nil DEBUG observer. The controlled RED omits only the compatibility version from `InstallationGeneration`: it reaches a stale review, adopts instead of cancelling, and changes the accepted index (three expected assertions; primary1/cleanup0). Restoring the existing production generation field passes the exact control (primary0/cleanup0). Both runs used the existing signing-dependent fixture with a local Developer ID, no signing bypass or native fixture execution, and both exact hosts exited per run. Evidence: `native-error-mode/task3-signed-discovery-{red,green}/`. Independent current-diff review found no actionable findings; Release excludes the observation seam. This validates stale discovery separately from actual vendor acceptance.

### Task4: Honest review and management controls

**Files:** `ExtensionConsent.swift`, `ExtensionManagement.swift`, `Extensions.swift` (`Entry`/diagnostics), `ExtensionConsentTests.swift`, `docs/DEVELOPMENT.md`.

**Interfaces:**
- Add defaulted `Entry.nativeMessagingErrorCompatibilityAvailable: Bool = false` and `nativeMessagingErrorCompatibilityEnabled: Bool = false`, derived from the accepted profile record and actual declaration.
- In the existing compatibility section offer `Review Error-Only Mode…` for eligible off records; offer `Disable Error-Only Mode` for on records. This separate post-install review is the initial-install offer too: ordinary installation never approves it. Disable controls while `host.isBusy` and surface transaction errors through the existing detail error UI.
- Prompt title: `Enable error-only desktop compatibility for “<name>”?`; description: `The extension can receive errors when it requests desktop integration. Vane will not connect to desktop apps. Desktop-dependent features remain unavailable.` Buttons: `Enable Error-Only Mode`, `Cancel` (Escape).
- Enabled status: `Error-only mode enabled. Desktop apps remain blocked.` Keep existing native-host-unavailable limitations visible and document that the SDK permission is granted only to expose real error callbacks; no host is registered or contacted.

- [x] Add prompt/model tests asserting separate explicit approval, correct labels, no claim of functional native integration, and ineligible/private/foreign-profile entries lacking the control.
- [x] Implement the entry values, prompt and compatibility-section actions using Task3's exact method; do not change existing Install/Update boolean approval semantics or native permission prompt filtering.
- [x] Run `python3 scripts/run-native-tests.py --build-system native --jobs 1 --filter 'ExtensionConsentTests|ExtensionNativeMessagingErrorTests'` and `git diff --check`; expect pass and primary0/cleanup0. Commit controls/documentation with this deliverable.

Task4 validation: the new entry test first failed compilation for missing fields, preserved in `native-error-mode/task4-entry-red-build.log`. A separate optional-native regression exposed `revokeRuntimeAccess` clearing the separately approved SDK permission; `task4-optional-revoke-red/` retains primary1/cleanup0 and both exact host exits. The repair retains only the accepted mode's native permission while revoking ordinary additional grants; the manager excludes that separately reviewed choice from temporary grants. `task4-related-green/` passed65 relevant tests (including18 mode/denial cases), primary0/cleanup0, both exact hosts exited. Diff check and scoped UI detector passed. The final actual manager inspection and independent current-diff review are recorded below.

Task4 visual follow-up: actual signed-package manager inspection (`management-visual-signed-7833f39aa050/`, visual-only, primary0/cleanup0, both hosts exited) confirmed layout/copy but exposed expected native errors incorrectly labeling the active extension “Update needs attention.” The real MV2 throw/listener fixture reproduced three status/visibility assertions (primary1/cleanup0), preserved in `runtime-status-red/`. Exact context-domain code7 diagnostics now have a separate visible section; all explicit failures, fatal callbacks, code6, unknown codes and wrong-domain errors keep the existing blocking status. `runtime-status-related-green/` passed74 relevant cases, primary0/cleanup0 and both exact hosts exited. Independent current-diff review found no actionable findings; scoped UI detector and diff check passed. Updated visual inspection remains pending; no actual-main or full CI repair is inferred from these local checks.

### Task5: Uninstrumented signed Store acceptance and integration

**Files:** add meaningful regression fixtures to `ExtensionNativeMessagingErrorTests.swift` as needed; update the approved spec/validation record and `docs/DEVELOPMENT.md`. Reuse existing task-only signed-package harness outside the repo; do not ship it.

- [x] Add a bounded sequential retry fixture with background timer and real SDK error callbacks. Its positive arm uses approved production mode; its negative arm retains hidden/denied legacy mode and reproduces starvation. Keep original deadlines and first-failure evidence; do not wait for a pixel/UI outcome as a readiness prerequisite.
- [x] Run relevant native controls through `scripts/run-native-tests.py` after admitting AppKit, foreground/document state and exact visible presentation owner. Include closed-by-default, approval, callback/Promise/port, cancellation, rollback, restart and cross-profile tests; maintain existing UA/storage/controller assertions.
- [x] Install the exact signed `/Applications/Bitwarden.app` Store2026.10.0 through the real production installer in a fresh signed task app, explicitly approve error-only mode, and verify actual compact action-window welcome/identity within the original20seconds. Close/reopen with a fresh SDK webview, then relaunch the process and repeat restoration. Verify both message and port requests remain errors and no native dispatch occurs; record bounded steady-state requests/timer liveness. No injected API/runtime interception or vendor edits in this acceptance arm.
- [x] Preserve provenance, original failures and positive cleanup; revalidate exact executable/PID/kernel start before any task-owned termination, retire scoped stores and verify exit. Leave the user's regular Vane/Bitwarden instances alone.
- [ ] Obtain independent review of the current shipping diff, address findings, pass required CI integrated with latest main (including the strict worker-UA classifier), and squash-merge per project workflow. Verify the fresh actual-main run and report the squash SHA/PR. Do not call issue484 fixed until this acceptance passes; do not close issue513.

Task5 progress (not complete): a managed closed/approved fixture now makes three real sequential SDK requests through an async wrapper and records queued microtasks, native-handler request counts, unavailable errors/no successful replies and timer opportunity. The closed control runs its three rejection continuations before the timer; reviewed mode yields to the timer during actual SDK errors. The final loaded-owner prerequisite includes foreground/key state before starting this probe. `task5-async-retry-control/` and the subsequent74-case `runtime-status-related-green/` retain final passing execution, primary0/cleanup0 and exact host exits. Independent review found no actionable retry-control findings. This bounded negative arm demonstrates the starvation mechanism without hanging the test process; original unbounded vendor failures remain preserved.

Clean product-API positive observations: `production-acceptance-folder-a5b6fae477d6/` and `production-acceptance-signed-3d1d2384d96d/` each passed installation, explicit separate mode review, fresh-process restoration and two fresh actual SDK action windows per process, all within one absolute20-second budget from each request through welcome. Eight welcome observations, exact UA/runtime/origin, page timer and bounded native denial rates were verified with no API interception/delegate replacement. Each distribution arm had primary0/cleanup0 and all three exact native hosts exited. Scope is local macOS27.0.1; this is not a macOS26 engine fix or issue513 resolution.

Earlier readiness failures are preserved rather than erased: `production-acceptance-folder-47d2ee41d8c2/` failed the compound popup-owner prerequisite, but its missing conjunct was not logged and remains unknown; `...-1ad7e77d6ce7/` failed foreground admission before installation. The helper corrected cooperative `NSApp.activate()` to the existing native fixtures' explicit foreground request and now records compound state after failure. API semantics support that foreground correction, but the later positives do not retrospectively establish47d2's cause. Acceptance qualification remains open while that boundary is audited.

### Current integration qualification (2026-10-29)

Shipping source `529f64d770d4499767216bd049fa6dc2cc9ebb8f` includes main `426b53f` and its file-picker implementation. Independent whole-diff review against that main found no actionable findings. The integrated extension cohort passed 134 cases with one existing live-store opt-in skip, primary 0 / cleanup 0; both exact hosts exited. This includes the mode tests, which extend `ExtensionNativeMessagingErrorTests` rather than introducing a separate XCTest class.

The acceptance helper now admits a complete controlled parent through the normal browser UI using one shared five-second budget, checks the selected tab/view/document/visible owner and foreground state before and after its bounded JavaScript reply, and repeats that admission before every action. The twenty-second welcome budget still begins immediately before `host.run`. A frozen, independently reviewed execution ran exactly one fresh folder arm and one fresh signed Store app arm: `production-acceptance-folder-05a4f48d01aa/` and `production-acceptance-signed-3723a492ff5a/`. Each passed install, separate approval, restart, two fresh SDK action windows per process, UA/runtime/origin, timer and bounded denials. All eight welcomes passed; each arm had primary 0 / cleanup 0 and all three exact hosts exited. Provenance, source/binary hashes, logs and PNGs remain in the task artifact directory. The earlier `2b3…` / `f1e…` arms are positive observations with subsequently identified admission gaps, not this final qualification. The historical `47d2…` missing compound conjunct remains unknown.

Actual manager inspection used a separate disposable profile and the signed app (`management-visual-signed-7c7a43077718/`). The real review dialog explained permanently blocked desktop integration; Cancel kept the mode off, then explicit Enable committed it. The manager showed Enabled, zero Needs Attention, a separate Runtime diagnostics section for the real vendor exception, and “Desktop apps remain blocked.” This visual-only run had primary 0 / cleanup 0 and both exact hosts exited. No user profile, account or regular app instance was changed.

This is local macOS 27.0.1 qualification. Required CI on the latest main integration, merge and actual-main verification remain outstanding. The separate earlier macOS 26 password-document stall remains under investigation; passing diagnostic samples do not repair it. Issue 513 remains open.

## Self-review result

Spec coverage maps to Tasks1–5: separate approval/default-off/persistence and source identity (1/3/4), permanent public denial/pacing/cancellation (2), unchanged grants outside approved mode and rollback (3), honest UI (4), signed production acceptance and integration (5). All five Review Focus conditions have explicit tests. Interface names match across tasks;100ms and20second values are retained. Compact-window implementation and CI reliability changes remain separate dependencies rather than extra scope in this plan.
