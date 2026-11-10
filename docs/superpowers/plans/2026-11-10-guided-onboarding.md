# Guided onboarding implementation plan

**Goal:** Build the approved interactive onboarding concept as native SwiftUI.

**Architecture:** Keep existing first-install detection and the browser-window presentation. Replace FirstLaunchView with a centered welcome and five guided steps; isolate the sample browser in WelcomeBrowserPreview.swift. Persist color and search through existing settings. Hand imports to the established native review after restoring the browser.

**Tech stack:** SwiftUI, AppKit, existing browser import APIs.

**Approved design:** User approved the November 10 interactive mockup with corrections: remove both supporting lines from the opening screen; show one logo; reveal Skip setup and step navigation only after Make yourself at home. Preserve the reference's quiet controls, large browser preview, and brief transitions.

## Tasks

- [x] Add native regression coverage for opening-screen controls, navigation, settings, and import handoff; observe failure on the existing UI.
- [x] Implement welcome → tabs/Split View → Space color → search → optional import → ready. Use sample content only in demos; do not create sample tabs or Spaces. Support keyboard navigation, small windows, light/dark appearance, Reduce Motion and Battery Saver.
- [x] Run focused FirstLaunch native tests, package the app, visually inspect representative sizes and appearance, and run pure selfcheck.
- [ ] Open PR, independently review the current diff, address findings, pass required CI on the latest base, show the native test app and leave the PR unmerged for the user’s review. Merge and cleanup await that review.

## Review focus

No duplicate logos or premature setup chrome on welcome. Settings apply to the current real Space and engine. Import restores the real browser before presenting existing consent UI and does not read source data before the user asks. Incoming links and first-launch completion semantics remain intact. Footer actions remain reachable at minimum browser size. Demo controls never create or navigate real tabs. Motion respects both policies.

## Validation record

Focused FirstLaunch and ImportWorker tests passed with primary and cleanup status 0. Packaged ad-hoc debug app and pure selfcheck passed. Native captures cover light/dark at 800×500 and 1200×800; compact spacing was tightened after an initial visual inspection. Initial AX-based fixture could not expose the SwiftUI button tree in this host, so regression tests use the actual setup model plus native rendering. No AX pass is claimed. User requested seeing the app before merge.

Final focused validation: 32 FirstLaunch/ImportWorker tests passed, primary 0 and cleanup 0. Native text checks validate visible opening CTA, absent supporting lines, delayed Skip setup, and visible step actions; native presentation coverage asserts restoration before continuation. Captures include minimum Split View. The first full-page OCR attempt misread the small header text; the preserved failure was investigated against the saved image, and the test now reads the header in its own region with English recognition.

## User feedback revision

Tightened intro gaps and darkened the ground. Browser previews now reuse production AddressPill (disabled under a sample-only overlay), SidebarRow, CommandField, PaletteResultRow, FavoriteTileBackground, and ThemeWashView. Space customization embeds the production ThemeEditor. Search selection uses bundled official icons and centered pill buttons.

Import now discovers known real-home browser locations with narrow read-only sandbox exceptions, scans asynchronously with progress, reviews counts and commits only after confirmation. No directory picker is offered. macOS privacy restrictions remain enforced and blocked sources are reported. General imports retain the reviewed source snapshot; Arc now also captures reviewed bookmark/history libraries and skips any unreadable/unreviewed library. Inline errors remain visible after import failures.

The old CI shard2 failure was only FirstLaunchViewTests.testNativeStepsRenderAtMinimumAndLargeWindowSizes: the runner capped NSWindow height at647 while the fixture requested800. The render viewport now sits inside a separate native container; exact viewport and OCR assertions remain. Original logs/annotations retained under /tmp/vane-onboarding-failed-shard2*. No CI retry was used as evidence. A coordinated focused revision run passed34 tests, primary0/cleanup0; fresh relevant review identified the three import/keyboard issues above, now repaired with additional coverage pending the next focused run. The central coordinator prohibits full CI, push, base updates and merge while the user reviews this draft.

Final revision validation: 44 focused FirstLaunch/OnboardingImport/ImportWorker/ArcRouting tests passed, primary0/cleanup0, including Arc library snapshot/count coverage and retained error state. Pure selfcheck and signed debug packaging passed. Review's three concrete P2 findings were repaired; fresh final review remains required before integration. Changes remain local under the central no-push/no-full-CI/no-base-update/no-merge gate while awaiting the user’s new-design approval.

## Guided viewport and Escape follow-up

Latest user feedback keeps native controls inside the guided sequence, restores a fixed16:10 browser preview, prevents Escape dismissal, and animates the first logo/headline. A fixed880×550 canvas now scales uniformly and stays centered. Welcome owns its entrance state, so outgoing transitions cannot hide a newly mounted intro; Reduce Motion/Battery Saver remain immediate. The presentation's hosting view consumes plain Escape and cancelOperation, and Skip setup has no cancel shortcut.

A fresh relevant read-only review found one pre-existing cancellation publication race. A deterministic worker-gate regression reproduced duplicate Arc IDs (2 instead of1) when a canceled scan completed after a newer review. Post-await cancellation/generation guards now protect candidate, issue, and progress publication; regression passes. Its RED evidence is `/tmp/vane-onboarding-cancel-red.log`. A separate actor-only combination exposed an AppKit initialization prerequisite for menu refresh; tests now initialize NSApplication.shared without activating/opening a window. Original crash evidence is `/tmp/vane-onboarding-cancel-green.log`. The arithmetic scaling test's1e-13 rounding failure was corrected with1e-9-point comparison tolerance while retaining exact ratio and viewport/OCR assertions.

Final combined46 FirstLaunch/OnboardingImport/ImportWorker/ArcRouting tests passed, primary0/cleanup0,20:46:21 local. Log `/tmp/vane-onboarding-final-focused.log`; native captures `/tmp/vane-onboarding-accepted-layout-captures`. User design approval and central integration gate remain required; no push, base update, full CI, or merge was performed.

## AI, source review, and live theme follow-up

User requested a guided AI page with AI off by default, broader automatic browser discovery, production sidebar geometry, live color/strength/grain, and showing selected-source contents. New-install defaults now agree across BrowserAI, AppleAI, Settings and contextual actions; explicit stored choices survive. Onboarding and Settings share the same AI feature controls. The guide now has six setup steps.

Known-path discovery adds Zen and Orion. Local non-content inspection established Orion's flat ID/parent/index bookmark plist and history_items/visits SQL schema with text CURRENT_TIMESTAMP timestamps. macOS denied access to Chrome/Edge/Brave roots on this host; discovery now reports these instead of silently hiding them. No bypass or folder picker is used. Selected sources show their immutable reviewed item lists and credential counts before confirmation.

The live render regression reproduced identical drawn pixels for held color, strength and grain edits, primary1/cleanup0 (`/tmp/vane-onboarding-live-red.log`). The drawn preview now observes the store directly. Sidebar header, footer markers, tile dimensions and favorite column layout use production components/tokens. Independent read-only review found Orion ID sorting could change the surviving bookmark folder/title on deduplication, plus the fixed-width preview header read the user's persisted width. Both are being repaired with source-order coverage and explicit preview width. Validation pending; no push/full CI/base change/merge.

Source-order regression reproduced the wrong first duplicate title/folder, primary1/cleanup0 (`/tmp/vane-onboarding-orion-order-red.log`). Orion now walks parent/child trees by sibling index with deterministic ID tie-breaks, preserving source order and rejecting cycles/orphans. The preview header receives its actual fixed width; the favorites grid uses production column calculation (four favorites form two rows). AI's built-in selfcheck now asserts opt-in default instead of hardware availability. A fresh focused run is in progress with no changes to existing outcome assertions or deadlines.

The66-case functional run passed65 cases, including all live-theme pixel, AI default, browser snapshot/order and TidyTitle cases. Only the newly added AI screen OCR assertion failed: Vision reads the capital-I glyph as lowercase-l (`AI`→`al`). Its first replacement targeted an off-state footnote that is below the fold at800×500; that failure is also retained. The fixture now verifies the screen heading and the always-visible sentence “stays off until you turn it on,” present in every saved capture. Existing exact viewport, header, footer, opening-content and action assertions/deadlines are unchanged. Logs `/tmp/vane-onboarding-ai-focused.log` and `/tmp/vane-onboarding-ai-passing.log` preserve both failed attempts. Pure selfcheck passes. Only the repaired native render case needs its final rerun; no product change followed the66-case run.

Final repaired native render fixture PASS, primary0/cleanup0 at21:14:48 (`/tmp/vane-onboarding-ai-render-final.log`), covering all seven screens at exact800×500/1200×800 viewports in light/dark plus minimum Split View. Together with the65 other passing focused cases, this validates the current product changes. Pure selfcheck and sandboxed signed debug packaging also passed. Independent review's actionable Orion ordering and preview-width findings are fixed. The preview remains isolated and user-review draft632 remains unpushed/unmerged under the central gate.

## Larger preview with production chrome

User requested a larger mock window that looks exactly like the browser. The preview cap grows720→880 and theme canvas600→680, keeping16:10 uniform scale. Production and guided sample now share SidebarChrome padding, SpaceSectionsLayout scroll/row geometry, BrowserPageSurface clip/rim/shadow, BrowserPaneSurface split borders, native TrafficLightRest drawing, SiteIcon, actual favorite column rules and LibraryDownloadGlyph. The invented page-top URL strip is removed; the production AddressPill displays the sample address through presentation-only metadata. The guide disables direct native window dragging inside its shared sidebar layout; production defaults remain unchanged. All sample actions remain isolated.

Independent read-only review found traffic-light positions were still invented despite shared painting. The sample now reads its host's actual standard-window-button x coordinates (with documented AppKit geometry for offscreen renders). Footer ink, marker spacing and header typography also match production tokens. Focused rendering/SidebarChrome validation and signed preview refresh pending; no push/full CI/base update/merge.

First18-case chrome validation passed17 cases; one full-page OCR pass missed Search's Continue despite the saved image clearly showing the footer (`/tmp/vane-onboarding-exact-chrome-tests.log`). Footer OCR now reads its own actual region, retaining the same required action text, exact viewports and all outcome deadlines, as header OCR already does. Visual inspection also exposed excessive preview overflow at ordinary heights. Tighter surrounding spacing and a viewport-based height budget now reserve room for the heading, complete16:10 preview and persistent footer at normal sizes; minimum sizes may still scroll. Original evidence is retained. Final validation pending.

The subsequent native render exposed fixture admission defects rather than product state: a1200×800 host was owned by an800×500 window, then an exact-sized ordinary titled owner exposed a32pt safe-area discrepancy (`visibleRect800×532` for declared800×500). The fixture now uses production fullSizeContentView/transparent-titlebar style and a fixture-only unconstrained owner, asserting both actual owner and host.visibleRect sizes before capture and returning on a failed prerequisite after recording the failure. Prior failed captures/logs remain under `/tmp/vane-onboarding-chrome-fit-*` and `/tmp/vane-onboarding-admitted-owner-*`. No existing layout/OCR requirement or deadline was removed. Product changes remain fully reviewed/local; native fixture revalidation pending.

Current validation limit: the production-style fixture now passes all exact owner/visibleRect assertions, but seven header OCR assertions still fail (`/tmp/vane-onboarding-native-style-tests.log`, primary1/cleanup0). Missing header captures remain unresolved; no passing retry or complete native validation is claimed. The17 other focused chrome/onboarding cases and pure selfcheck passed, and the signed isolated preview is prepared for the user's required design review. No push/full CI/base update/merge. Further integration must resolve the native header-render/capture issue.
