# Favourite preview validation — 2026-10-12

## Scope

macOS 27.0.1, Swift/Xcode 27 toolchain, minimum product runtime remains macOS 26. Native app checks used an ad-hoc signed, uniquely identified task-owned Vane copy and isolated fixture data. The normal installed Vane was used only for read-only inspector checks against existing signed-in pages, then its original tab was restored. No credentials were exported and no message subjects, sender values or event details were emitted by diagnostics.

## Focused validation

`swift test --filter 'FavouritePreview|KeyboardAccessibilityTests|PreviewLoadingPerformanceTests|FavouriteLandingTests|ProfilePersistenceTests'`: 60 tests passed. Coverage includes both GitHub DOM layouts and available checks labels, Gmail sender/subject/unread/time/thread extraction, structured Calendar event/meeting fixtures, signed-out/empty/unknown/partial failures, URL restrictions, profile/account/route cache isolation and expiry, request replacement/cancellation, blocked data clears, stale refresh failures, signed-out cache purge, cookie restart limits, hover dwell/transfer/dismissal, keyboard shortcuts, native panel focus promotion and Return activation, plus existing keyboard/profile/link-preview regressions. A populated native Gmail fixture was rendered and visually inspected against the user’s Arc reference.

`./.build/debug/vane selfcheck --pure`: PASS. `./make-app.sh debug`: signed sandboxed debug bundle built. `git diff --check`: clean.

The first PR CI run tested 1,091 cases (41 skips), with one failure in a new fixture’s fixed-delay scheduling assumption. The fixture now waits for explicit completion with a deadline. CI for the final head must pass before merge; the failed run is not treated as a pass.

## Live evidence and limits

| Flow | Evidence |
| --- | --- |
| Gmail authenticated page | Read-only inspector diagnostics recognized account identity and five visible inbox rows, each with sender, subject, legacy thread ID and website time label. Fixture parsing validates unread extraction and URL construction. No message content was returned to diagnostics. |
| GitHub authenticated PR list | The normal /pulls query redirected to /pulls/search. Observed five title links in list items and a checks-status badge. Adapter and fixture updated to this actual layout; status is copied only when exposed by the row. |
| Calendar authenticated schedule | Account recognized; 42 event nodes, zero canonical event links and zero machine-readable times in the observed layout. Rich extraction is unavailable for that layout; the card offers Open Site and does not claim the calendar is empty. |
| Isolated app services | GitHub/Gmail signed-out cards and Calendar unavailable fallback observed. Open Site created a new Today tab in the same test profile. Final build: Tab focused Compose and Return opened its website URL in a new same-profile tab, which redirected to sign-in/marketing because the test profile was signed out. |
| Accessibility/keyboard | VoiceOver preview action and correctly labeled child actions observed. ⌥↓ opens a focused favourite’s card; Escape dismisses and restores favourite focus. Tab focus and Return activation of Compose were checked in the final app. Native fixtures verify passive hover-panel focus, keyboard promotion without recreation and Return activation of Open Site. |
| Pointer interaction | Dwell, cancellation and tile/card transfer grace pass focused fixtures. Native automation provides click/drag but no hover-only pointer action; physical pointer-only hover and transfer could not be conclusively verified in the app. |

Authenticated end-to-end cards, opening a live message/PR, Gmail’s authenticated compose screen, and joining a live event meeting remain unverified. Calendar’s structured event path is fixture-tested, not established for the current live schedule. Account redirects, other locales and layout changes may fall back. Profile-wide cookie invalidation is conservative and may also invalidate a preview after an unrelated site changes cookies. Private previews provide website actions without extracting session content.

Task app process identities and start times are tracked outside the repository. All task-owned Vane instances must exit before reporting merge completion; the normal installed Vane must remain running.
