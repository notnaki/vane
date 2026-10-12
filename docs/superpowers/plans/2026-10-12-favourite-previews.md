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
- [ ] Write tests for `FavouritePreviewService.resolve(_:)`, `FavouritePreviewAdapter.parse(_:at:)` and `FavouritePreviewCache` profile/account isolation, stale expiry and clear.
- [ ] Run `swift test --filter FavouritePreviewTests`; confirm missing-type failure.
- [ ] Implement service recognition, canonical account routes, common item/snapshot/state models, strict URL validation, bounded parsers and memory cache.
- [ ] Add WebKit DOM fixture tests for signed-in GitHub/Gmail/Calendar, empty and changed markup. Execute adapter scripts against fixture HTML rather than mocked JSON alone.
- [ ] Run focused tests and commit adapter/cache deliverable.

### Task 2: Bounded WebKit coordination and invalidation
Files: create Sources/Vane/FavouritePreviews.swift; modify ClearData.swift, WebsiteData.swift, Profiles.swift, EraseEverything.swift; extend FavouritePreviewTests.swift.
- [ ] Write cancellation/replacement/invalidation tests against injectable loader interface.
- [ ] Run focused tests and confirm failure before implementation.
- [ ] Implement one active request, 8s deadline, bounded readiness retries, 30s cooldown, cookie observer, cancellation and generation guards.
- [ ] Use `Tab.configuration(isPrivate: false, profileID:)`, disable extensions/autoplay/popups/downloads and constrain top-level navigation to service and sign-in hosts. Never use URLSession for authenticated data.
- [ ] Wire invalidation before and after website-data removal and on profile deletion/erase. Add global/per-service preference cancellation.
- [ ] Run focused tests and commit coordinator deliverable.

### Task 3: Native interactive card and preferences
Files: create Sources/Vane/FavouritePreviewCard.swift; modify UI.swift and SettingsWindow.swift.
- [ ] Add hover lifetime tests for dwell, region transfer, Escape and cancelled dwell.
- [ ] Implement tile modifier with shared hover lifecycle, keyboard/context-menu/VoiceOver preview command and native card buttons.
- [ ] Render distinct loading/signed-out/stale/empty/unavailable states and route actions through owning store's `newTab(_:)`.
- [ ] Add global and per-service toggles independent of linkPreviews, and motion-policy-aware transitions.
- [ ] Build signed isolated debug app; record PID, launch time and bundle; exercise actual pointer and keyboard UI and capture evidence in validation doc.
- [ ] Commit UI deliverable.

### Task 4: Review and merge
- [ ] Run `swift test --filter 'FavouritePreview|PreviewLoadingPerformanceTests|FavouriteLandingTests|ProfilePersistenceTests'`, relevant pure selfchecks and diff check.
- [ ] Update user-facing integration/privacy docs and record live/fixture coverage.
- [ ] Push branch, open PR and attach it to the chat.
- [ ] Obtain independent review of current commit, fix actionable findings and repeat relevant tests/review.
- [ ] Confirm required CI, approvals and mergeability; squash-merge; verify merge SHA.
- [ ] Quit and verify exit of task-owned app, preserve regular Vane, report PR/SHA/validation/limitations.

## Ledger
- Initial checkout is another task's branch; native isolated worktree created from remote default branch to preserve it.
- Integration ruling: website session is the sole authority; Live Folders OAuth is intentionally excluded.
- Calendar ruling: only explicit event times/links permit rich data; unknown layout uses useful fallback.
