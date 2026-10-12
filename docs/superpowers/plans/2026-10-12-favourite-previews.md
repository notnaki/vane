# Rich Favourite Previews Implementation Plan

**Goal:** Add session-backed site-specific favourite cards without changing the current tab.
**Architecture:** Separate adapters, validated models/cache, one bounded WebKit coordinator and native SwiftUI presentation. Reuse profile configuration, theme/motion and TabStore navigation.
**Tech Stack:** Swift 6, SwiftUI, AppKit, WebKit, XCTest.
**Spec:** docs/superpowers/specs/2026-10-12-favourite-previews-design.md
**Execution:** Inline using executing-plans; independent whole-PR review. User waived additional design approval gates.

## Global constraints
No backend, cloud AI, new keys/OAuth, private endpoints or exported session credentials. Memory-only profile/account isolation. macOS 26. Never report extraction failure as empty. No message/event content logging.

## Review focus
- Switching Google accounts within one profile cannot reuse another account's content.
- Unrecognized markup and partial parsing cannot appear as an empty inbox or schedule.
- Site-data clearing cancels loaders before and after asynchronous removal.
- Hover dismissal cannot publish a late load into a different card/window.
- Hostile item URLs and external redirects cannot trigger automatic side effects.

### Task 1: Models, adapters and cache
Files: create Sources/Vane/FavouritePreviewModels.swift, Sources/Vane/FavouritePreviewAdapters.swift, Tests/VaneTests/FavouritePreviewTests.swift.
- [x] Write tests for `FavouritePreviewService.resolve(_:)`, `FavouritePreviewAdapter.parse(_:at:)` and `FavouritePreviewCache` profile/account isolation, stale expiry and clear.
- [x] Run `swift test --filter FavouritePreviewTests`; confirm missing-type failure.
- [x] Implement service recognition, canonical account routes, common item/snapshot/state models, strict URL validation, bounded parsers and memory cache.
- [x] Add WebKit DOM fixture tests for signed-in GitHub/Gmail/Calendar, empty and changed markup. Execute adapter scripts against fixture HTML rather than mocked JSON alone.
- [x] Run focused tests and commit adapter/cache deliverable.

### Task 2: Bounded WebKit coordination and invalidation
Files: create Sources/Vane/FavouritePreviews.swift; modify ClearData.swift, WebsiteData.swift, Profiles.swift, EraseEverything.swift; extend FavouritePreviewTests.swift.
- [x] Write cancellation/replacement/invalidation tests against injectable loader interface.
- [x] Run focused tests and confirm failure before implementation.
- [x] Implement one active request, 8s deadline, bounded readiness retries, 30s cooldown, cookie observer, cancellation and generation guards.
- [x] Use `Tab.configuration(isPrivate: false, profileID:)`, disable extensions/autoplay/popups/downloads and constrain top-level navigation to service and sign-in hosts. Never use URLSession for authenticated data.
- [x] Wire invalidation before and after website-data removal and on profile deletion/erase. Add global/per-service preference cancellation.
- [x] Run focused tests and commit coordinator deliverable.

### Task 3: Native interactive card and preferences
Files: create Sources/Vane/FavouritePreviewCard.swift; modify UI.swift and SettingsWindow.swift.
- [x] Add hover lifetime tests for dwell, region transfer, Escape and cancelled dwell.
- [x] Implement tile modifier with shared hover lifecycle, keyboard/context-menu/VoiceOver preview command and native card buttons.
- [x] Render distinct loading/signed-out/stale/empty/unavailable states and route actions through owning store's `newTab(_:)`.
- [x] Add global and per-service toggles independent of linkPreviews, and motion-policy-aware transitions.
- [x] Build signed isolated debug app; record PID, launch time and bundle; exercise available pointer and keyboard UI and capture evidence in validation doc.
- [x] Commit UI deliverable.

### Task 4: Review and merge
- [x] Run `swift test --filter 'FavouritePreview|PreviewLoadingPerformanceTests|FavouriteLandingTests|ProfilePersistenceTests'`, relevant pure selfchecks and diff check.
- [x] Update user-facing integration/privacy docs and record live/fixture coverage.
- [x] Push branch, open PR and attach it to the chat.
- [ ] Obtain independent review of current commit, fix actionable findings and repeat relevant tests/review.
- [ ] Confirm required CI, approvals and mergeability; squash-merge; verify merge SHA.
- [ ] Quit and verify exit of task-owned app, preserve regular Vane, report PR/SHA/validation/limitations.

## Ledger
- Initial checkout is another task's branch; native isolated worktree created from remote default branch to preserve it.
- Integration ruling: website session is the sole authority; Live Folders OAuth is intentionally excluded.
- Calendar ruling: only explicit event times/links permit rich data; unknown layout uses useful fallback.

- Adapter/model RED: missing-type compilation failures observed; GREEN: 8 parsing/cache/DOM tests passed.
- Coordinator RED: missing loader/coordinator types and clock injection; GREEN: cancellation, replacement, blocked clears, cache reuse, cooldown, stale failures and signed-out purge passed.
- Hover RED: missing hover controller; GREEN: dwell, pointer-region transfer, keyboard latch and dismissal tests passed.
- Ruling: live account proof is required for a cache hit; parked favourites may pay a fresh bounded page load. This sacrifices some cache hits to avoid guessing account identity.
- Ruling: cookie changes conservatively invalidate the whole profile, without reading cookie values; unrelated cookie changes can also dismiss a preview.

- Independent review of 2d06fcb found one P2: promote an existing hover panel on keyboard opening. Added a native regression fixture; observed failures for both key promotion and Return activation, then fixed promotion, initial action focus and owner-focus restoration. The regression now passes.
- Ruling: use an owned native child panel instead of SwiftUI's transient popover because live app checks showed the popover dismissed on focus traversal. The panel remains passive on hover and becomes key for keyboard/VoiceOver opening.
- Ruling: allow at most one restart for cookies set during normal page loading. Each load remains capped at eight seconds, for a total of at most sixteen seconds of loading per hover; repeated changes fail closed.

- Live read-only inspector checks (count/boolean diagnostics only): Gmail recognized account and five rows with all sender/subject/thread/time fields. GitHub redirected to /pulls/search; updated adapter to its observed title-link/list-item/checks-badge structure and added a failing-then-passing DOM fixture. Calendar exposed 42 event nodes but zero canonical event links or machine-readable times; unsupported fallback is appropriate for that observed layout.
- User supplied Arc reference; Gmail now uses sender-first divided rows, website time labels, bounded scrolling and a compact Compose control. Native fixture render inspected.
- CI at 2d06fcb ran 1,091 tests with one failure in the new lifecycle fixture: a fixed 90ms wait could run before the first response on a busy runner. Replaced fixed scheduling assumptions with bounded waits for explicit response/state completion. Local focused validation passes after the correction.

- Final isolated app check: Tab moves from Open Site to Compose; Return opens the website compose URL in a new tab in the owning profile (signed-out redirect). Escape dismisses and restores favourite focus; Option–Down reopens. Normal quit confirmed and PID 22612 exited. Physical pointer-only hover remains unverified, as documented.
