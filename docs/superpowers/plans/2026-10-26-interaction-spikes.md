# Interaction spike reduction

**Goal:** Remove measured rendering stalls from ordinary browser interactions, starting with rapid populated Space navigation and checking scrolling, tab selection, search, and panel presentation.

**Architecture:** Keep WebKit/AppKit presentation on the main actor. Avoid constructing fallback SwiftUI trees when native presentation owns the interaction, eliminate irrelevant subscriptions in captured presentation, and scope synchronous layout to the surface that needs it. Preserve the existing appearance, interruption behavior, data protection, and motion policies.

**Stack:** Swift, SwiftUI, AppKit, Core Animation, XCTest.

The user's supplied 120 Hz recordings and report of roughly 100 ms update spikes define the problem. Native callback availability, input admission, and compositor presentation are distinct measurements; passing a state-machine test does not establish smooth presentation.

- [x] Reproduce rapid switching with populated Spaces and sample the blocking stacks; collect optimized baseline input and display-cycle measurements without a competing build.
- [x] Add a regression for duplicate fallback sidebar mounting during native preparation. Verify failure before changing `SpaceSidebarStrip` in `Sources/Vane/SpacesUI.swift`.
- [x] Remove the demonstrated duplicate rendering and redundant observed-state dependencies. Keep original native-row pixel parity, protection revocation, focus, and fallback behavior covered by their existing fixtures.
- [ ] Re-measure populated switches and normal browser interactions. Investigate remaining stalls rather than treating improved averages as completion.
- [ ] Run focused rendering, interruption, scrolling, search, and motion-policy checks; inspect the native result. Obtain independent current-diff review, fix findings, pass required CI, squash-merge, and clean up owned processes and this worktree.

Review focus: rapid same-direction gestures; reversal before landing; cross-profile navigation; locked/collapsed/deleted rows; a cold surface without prepared neighbors; a loaded page surviving chrome updates; Reduce Motion and Battery Saver.

## Findings and rejected changes

- Populated rapid swipes reproduced 110–179 ms input stalls in the optimized baseline. Sampling attributed most claimed-input time to `beginSpaceSlide` forcing the complete window display/layout cycle.
- The initial claim mounted fallback lists inside the live hosting tree before the native overlay took ownership. Keep the live rows until the native overlay owns them instead; the duplicate-mount regression failed before this correction.
- Native gesture setup published three intermediate states for one finger packet. Publish its coherent presentation once; the publication-count regression failed before batching. Preserve SwiftUI animation transactions for nonnative edge returns.
- Native travel now keeps the covered live scroll/layout/focus shell mounted. Reset the viewport offset and local header/drop/sheet state on logical Space changes; uncovered navigation still gets a fresh identity for its normal transition. The native-to-direct return regression failed before the identity-generation correction.
- Drag insertion markers now measure only the active gap through a native coordinate relay, replacing anchor-preference reduction across the outline. Download anchors mount only during download feedback.
- Footer display progress observes only marker ink; the menu/popover/keyboard containers retain their body across finger samples.
- Frozen native captures omit live row observation and invisible close controls, and skip intrinsic-size fitting probes because their native frames are explicit.
- Landing no longer activates an already-selected neighbor or rebuilds the same menu a second time. The completion-menu identity regression failed before the correction.
- Eagerly mounting the bounded command-bar results improved debug scrolling but increased optimized typing callback gaps. Discarded it after matched release comparisons; retain the original lazy mounting.
- Narrowing a cold overlay's display call to its subtree failed the existing compositor-readiness regression. Discarded it; hiding live content before the replacement is attached is incorrect.
- Giving the palette a separate hosting boundary did not improve measured callback gaps. Discarded it.
- Eagerly mounting all frozen sidebar rows made populated swipe admission worse and broke the malformed-small-shape fallback assertion. Discarded it.

Timing runs must be made after compilers and sampling stop. Optional cadence assertions are local diagnostics, separate from CI correctness and from actual compositor-presented FPS.
