# Selective Link Previews Implementation Plan

**Goal:** Stop speculative previews for ordinary navigation and make intentional previews quiet and stable.
**Architecture:** Filter links in the existing document hover script before crossing the native bridge; retain native eligibility and lifecycle controls. Present one settled image in a compact SwiftUI card.
**Tech Stack:** Swift, SwiftUI, WebKit, XCTest.
**Spec:** ../specs/2026-11-14-selective-link-previews-design.md

- [x] Add WebKit regressions for ordinary navigation, search results versus pagination, and HN stories versus comments. Run against the current script and retain failures.
- [x] Add selective site/DOM gates, a deliberate hover dwell and the Shift override. Cover modifiers, pointer exit and downloads.
- [x] Replace repeated image publication with a single settled snapshot; refine loading, image and text presentation and update settings copy.
- [x] Validate focused hover, loading/performance and presentation tests; visually inspect native rendered cards.
- [ ] Open PR, obtain independent current-diff review, fix findings, wait for required current-base CI, squash merge and clean the task checkout.

- [x] Add and observe regressions for short-text whitespace and deferred first paint, then fix bounded blank retries and navigation identity checks.
- [x] Replace fixed phase heights with intrinsic layout; add a grapheme-safe typing state and animated card entry, growth and exit. Validate prefix updates, rewrite/retraction, reduced motion and actual native rendering.

Validation: 36 focused native tests passed with primary status 0 and cleanup status 0. Native captures checked compact loading/metadata/completed states and mounted intermediate typing heights. Pure selfcheck passed. Independent review found no remaining actionable implementation issue. Required PR CI and merge remain pending.

Final integration: rebased onto fc29a297. A presentation admission failure showed the app inactive and the new page window hidden after the typing fixture's regular-to-prohibited activation handoff. The typing fixture now uses the existing activation policy and orders its window without activating the app. Three predetermined presentation preflights passed (11 tests each, cleanup verified); the combined 36-test suite then passed on the integrated tree with cleanup verified. Matching image/card corner radii were also requested and validated in the native presentation suite.

Final user approval retained rounded outer card corners and square image clipping. The 11 presentation tests passed after that change. A signed screenshot copy was built and launched with isolated data; the user checked the result and approved it. Computer Use subsequently failed to capture a screenshot with ScreenCaptureKit error -3811; no mockup was represented as an app screenshot.

Required CI follow-up: run 43514239404, native shard 4, failed on b6efa117 in extension retry preparation (`incompleteHeartbeat`) and sidebar pointer-intrusion admission (phase 0). A controlled one-sample launch-readiness withdrawal reproduced the extension failure before repair. Preparation now uses the loop's bounded interaction-readiness predicate while retaining fatal cancellation, policy and lifecycle checks and existing action/result deadlines. The sidebar fixture binds its hover actuator with its exact native probe instead of a separate onAppear event and clears it only when that owner dismantles. Three predetermined 12-test preflights all passed with verified retirement cleanup; independent review approved the repair diff. User-approved product preview behavior is unchanged. Full required CI remains pending on the repaired head.
