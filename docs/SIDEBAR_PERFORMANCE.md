# Sidebar presentation investigation — 2026-10-10

## Retained fix

`SpacePreviewList` loaded the profile's saved Space sidecar even when every tab
row rendered through an existing `SidebarTabSurface` or `PaneStrip`. Loading
also JSON-decodes and base64-decodes opaque WebKit interaction states. Those
states are unused by the live surfaces, but the synchronous work delayed preview
capture before a Space transition.

Skip this load only when live tabs and a render store exist and the favourite
grid is excluded. Saved previews, previews without a render store, and favourite
grids retain their saved-page/title fallbacks. No engine, view hierarchy,
animation, security filter, selection or persistence behavior changes.

## Method

The opt-in fixture hosts a real 900×700 `BrowserWindow` in a visible native
window, using registered scratch profiles with 20 and 300 parked tabs, a third
pinned, and no loaded pages. A two-tab fixture warms framework/singleton paths.
The saved sidecar contains 16 KiB of synthetic opaque state per tab; the 300-tab
file is approximately 6.4 MB after JSON/base64 encoding. This is a deliberately
populated case, not an estimate of a typical user's session.

Optimized release builds use `-enable-testing`, full motion, battery power, macOS
27.0.1 and Xcode 27.0. Both comparison executables use base `cff8f25`; the only
production difference is the conditional preview load. A shared filesystem lock
serializes local profiling, followed by 30 continuous seconds without competing
builds, tests or task-owned apps. Runs detect competing workloads and must be
discarded if contaminated. No peer messages are needed.
Timing windows use the same floating window level in both versions to stay
visible while other desktop apps are used. Interactive fixtures use the normal
window level. Two earlier occluded comparisons were discarded.

Each operation has five repetitions and 400 ms settling intervals, except ten
scroll/swipe repetitions and three preview mounts. Append and remove reset to
the same initial cardinality between repetitions. Reorder commits through
`applyOrder`. The 1 ms common-mode timer reports the largest main-run-loop gap
per repetition, including deferred layout and animation work. These gaps and
action durations are diagnostics, not CI thresholds or frame-rate estimates.

Selection and cached Space-switch cases use inert recovery pages: they measure
presentation, not WebKit creation or page load. Cached Space switching includes
engine work and is not a cold restoration benchmark. Cached `body` construction
is reported separately and does not measure native rendering. The synthetic
mouse-moved event did not trigger hover reveal; it was excluded from timing
claims. Hover behavior requires the real-pointer interactive check.

## Attribution and rejected experiment

A separate 50-second `/usr/bin/sample` capture of the large fixture found deep
SwiftUI stack-layout/AttributeGraph updates beneath `OpenTabs`, `PinnedSection`
and `SidebarTabSurface`. Of 27,843 main-thread leaf samples, 18,002 were idle
`mach_msg2_trap`; active samples included graph updates and dirty propagation.
Preview capture stacks also included `SpacePreviewList.init` →
`Suspension.SpaceState.load` → JSON scanning/decoding. Sampled-run timings are
excluded from the comparison because sampling adds substantial overhead.

The live 300-tab sidebar mounted 300 native tab anchors. An experimental
fixed-extent lazy stack attempted to reduce offscreen work, but a native pixel
comparison against the eager layout failed at middle/bottom scroll offsets
(93,825 and 69,129 differing bytes). The experiment was discarded. Large eager
layout costs remain; preserving focus, rename lifetime, scroll geometry and
visual continuity requires a separate solution.

The parked-profile parity test also exposed an independent test race: its live
top cutoff was captured during a fade while the ghost cutoff was static. All
1,452 differing channel bytes in an isolated reproduction were on that one
divider scanline. The test now disables animations for its static geometry
comparison; production motion and the dedicated motion-policy tests are intact.

## Reproduction

Run on an otherwise idle, logged-in macOS desktop:

```sh
python3 scripts/profile-sidebar-presentation.py --output /tmp/sidebar-evidence
```

The runner builds the opt-in test fixture as a signed native diagnostic app.
It retains build logs, metrics, process identity and a contamination record in
the new output directory, removes scratch data/preferences, and waits for the
owned process to exit. It supports Xcode's SwiftPM build backend. A stale shared
lock causes a bounded failure; inspect its owner before removing it.

For manual scrolling, tab actions, keyboard focus, drag/drop, real-pointer hover
and Space-switch checks with a populated neighbouring stash:

```sh
python3 scripts/profile-sidebar-presentation.py --output /tmp/sidebar-interactive --interactive 300
```

Interactive mode lasts four minutes and permits reduced-motion policies. Use
`20` for the small fixture. Reuse a previously built diagnostic with
`--app '/path/to/Vane Sidebar Profile.app'`; this is not a production Vane app.
Timing mode requires system Reduce Motion and Battery Saver to be off; policy
behavior is checked separately. Ctrl-C stops only the runner's owned child.

## Results and limits

The matched visible runs both exited successfully without competing workloads or
visibility failures. The after run also confirmed an unchanged power source at
its start and end. Earlier stack attribution used AC power; its timings are not
part of this comparison.

| Operation, median ms | 20 before | 20 after | 300 before | 300 after |
| --- | ---: | ---: | ---: | ---: |
| Accessible tabs | 0.15 | 0.28 | 3.84 | 4.39 |
| Row models | 0.35 | 0.34 | 8.78 | 10.80 |
| Selection, recovery UI | 29.31 | 26.67 | 172.17 | 169.36 |
| Append UI row | 34.78 | 36.81 | 188.87 | 189.20 |
| Remove UI row | 25.19 | 28.00 | 160.73 | 160.44 |
| Reorder | 22.38 | 23.11 | 141.81 | 144.12 |
| Scroll | 6.83 | 7.34 | 45.78 | 33.71 |
| Live preview capture | 4.51 | 1.03 | 40.42 | 4.16 |
| Disk preview capture | 5.92 | 7.18 | 43.27 | 39.30 |
| Cached body construction | 0.06 | 0.08 | 0.06 | 0.06 |
| Preview mount/layout | 48.84 | 44.88 | 359.50 | 375.74 |
| Swipe frame/layout | 5.01 | 12.55 | 75.61 | 93.56 |
| Sidebar reveal/layout | 81.38 | 82.97 | 753.53 | 769.94 |
| Cached Space switch, recovery UI | 143.11 | 144.32 | 1282.30 | 963.61 |

The 300-tab live-capture reduction is 89.7%. Its median main-run-loop gap fell
from 40.46 to 5.96 ms; maximum gaps fell from 48.57 to 25.87 ms. Saved preview
capture remains expensive because it still needs saved metadata. No improvement
is established for the other operations: the table includes unchanged and higher
after timings, especially preview mounting and swipe-frame layout. Cached Space
switch gaps remain over a second (median 1,285 before / 1,411 ms after).

Validation: optimized build; 86 focused tests, one opt-in diagnostic skipped, zero
failures. Coverage includes preview pixel parity, folders, splits, selection,
scroll offsets, drag/drop, ordering, keyboard accessibility, Reduce Motion and
Battery Saver. The profiling runner built and launched a native probe, detected
occluded runs, and verified process/scratch cleanup. Native interactive checks
are recorded in the PR.

Results apply to these fixtures and this machine. Active web pages, cross-profile
saved metadata, cold restore, different hardware and minimum-runtime macOS 26
performance are outside this comparison. No claim is made that the retained fix
resolves the remaining eager row-layout stalls.
