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
