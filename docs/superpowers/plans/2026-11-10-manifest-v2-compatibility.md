# Manifest V2 compatibility implementation plan

**Goal:** Add as much MV2 compatibility as system WebKit safely supports, as requested after comparing the full byearc browser list.

**Architecture:** Preserve WKWebExtension's MV2 execution and vendor resources. An installation-scoped uBlock Origin adapter reads selected, decoded cached lists and trusted sites in the actual extension background page. Translate supported static filters into separate WKContentRuleLists; attach only to this profile's normal browsing controllers. Do not expose a pretend blocking webRequest API.

**Constraints:** macOS 26 minimum; no new dependencies, engine swap, vendor code copying, storage-database access, silent extension-code edits, private browsing extension grants, or cross-profile blocking. Explicitly report unsupported filters, read/compile failures and missing bridge prerequisites. Disable/removal/permission revocation must detach rules and invalidate outstanding results. Preserve the existing built-in blocker independently.

**Research:** Full matrix inspected (all listed browsers, including unknown/unsupported rows). Crest, Cra, Oblada, Ardia and Arcium patch Chromium's MV2 deprecation gate; Zen/Floorp inherit Firefox blocking webRequest. WebKit peers load MV2 but inherit observational webRequest. myBrowser's independently documented bridge establishes feasibility of static-list translation, not full uBlock parity. Its source has no declared license; do not copy it. Sources and limitations will be recorded in the development guide.

## Task 1: Static-rule translation and diagnostics

- [x] Add failing tests for MV2 blocking limitations, important/exception precedence, trusted domains/URLs, chunk-local exceptions, unsupported syntax and input bounds.
- [x] Implement `ExtensionFilterRules.compile(texts:trustedSites:)` using the existing EasyList converter, preserving precedence across chunks. Omit resource options that would broaden matching. Return bounded diagnostics.
- [x] Run focused converter/diagnostics tests and preserve red/green evidence.

## Task 2: Background snapshot and lifecycle

- [x] Add a synthetic MV2 uBlock-shaped package and real WebKit resource-load fixture proving blocking, unblocking, profile isolation, settings refresh and disable cleanup.
- [x] Implement background snapshot extraction through extension APIs, with unchanged-snapshot detection, bounded payloads, no external fetches and decoded modern/legacy caches. Fallback only to package-local assets. Respect empty list selection and trusted-site semantics.
- [x] Implement an installation-owned compiler/attachment lifecycle with cancellation checks after asynchronous boundaries and profile-scoped controller tracking. Refresh settings periodically; clear on disable/removal, host disposal, loss of access or an unreadable policy. Ruling: detach on failure instead of retaining old trust/selection decisions.
- [x] Show bridge status and limitations in existing extension compatibility reporting, and verify existing MV2/MV3 behavior.

## Task 3: Validation and integration

- [x] Run focused native cohorts with the cleanup wrapper, build, and diff checks. Inspect actual uBlock package behavior if available; do not generalize synthetic passes.
- [ ] Obtain independent current-diff review, fix findings, open/link the PR, satisfy required CI, recheck target/main runs and squash-merge under repository policy.
- [ ] Verify task host exit, preserve evidence, and remove the task worktree after merge.

## Review focus

Trusted-site patterns must never silently broaden. Partial reads must never install an incomplete selection. A delayed compile must never reattach a disabled/replaced extension. Optional/revoked host permissions must not become global rules. Empty selections and deleted user filters must remove their previous rules.

## Actual-package findings and implementation rulings

- Official uBlock 1.76 eagerly imports `chrome.privacy` setting methods. A uBlock-only document-start shim provides throwing methods, preserving explicit unsupported behavior while allowing its own error handling to finish startup.
- It borrows `runtime.getURL` onto its vAPI object. WebKit requires the native receiver, so the scoped shim binds that method; the actual-package failure and a synthetic detached-receiver regression established the gap.
- It unconditionally registers `webNavigation.onCreatedNavigationTarget`, which WebKit omits. Derive useful tab-level notifications from actual `tabs.onCreated` events and live native opener metadata, without fabricating unknown frame/process identifiers. Keep the missing metadata and incomplete popup-blocking behavior explicit.
- Generated MV2 background HTML defaults to windows-1252 on the local WebKit. The fixture now uses an explicit UTF-8 page matching the real package; vendor code is not rewritten to hide this fixture error.
- Independent review required omitting adapter cosmetics, excluding document loads, rejecting invalid important exceptions and unsafe wildcard authorities, and bounding persistent compiled-cache growth. Those fixes have ten passing pure cases; lifecycle and actual-package validation continue separately.
- The real package reaches `readyToFilter` before completing startup. Strengthened the actual-package fixture to require its completed-startup statistic and a real registered Vane tab. Added native callback/promise alarm round trips after reproducing WebKit's trailing-callback rejection, cooperative idle support in its isolated content world, and explicit host semantics for deferred-update registration and an empty webRequest decision cache. Scope remains partial WebKit compatibility; no synchronous request interception is invented.

## Final local evidence

`api-lifetime-green.log`: 16 cases, zero failures, primary0/cleanup0. Requires real uBlock1.76 completed startup, cache decoding and page initialization; fixes late loss of shim members by retaining WebKit's weakly cached native API wrappers in the extension realm.

`final-related-regressions.log`: 57 cases, one existing live-store opt-in skip, zero failures, primary0/cleanup0. Includes MV2/MV3 execution/storage/action, consent, lifecycle, runtime permissions, store lifecycle, blocker, popup and tab-order cases. `git diff --check` passed. Both logs and original red/investigation attempts remain under `/tmp/vane-manifest-v2-artifacts/`.

Full CI and the first push/merge must be coordinated with central thread `05a7ccb0-fac6-4846-b631-926ef9edcdd3`. Local readiness does not establish latest-main integration or minimum-macOS candidate behavior. The task worktree remains until integration preserves the work.
