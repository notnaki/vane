# Native rendering experiment

This is a default-off prototype on `codex/render-performance-experiment`.
It tests native UI work; it does not change WebKit's page renderer or enable a
different GPU backend. No change is proposed for the shipping defaults yet.

## Candidates

1. **Isolate frequent page signals.** Page progress and hovered links have their
   own observable owner. Only the loading pill and status capsule observe it.
   The experiment removes those signals from whole-tab invalidation, including
   the sidebar, address controls and page hosts. Other published tab metadata and
   explicit name/mute invalidations remain synchronous. Legacy mode forwards the
   signal owner's synchronous notification to the tab.
2. **Avoid cache-hit allocations.** Validate sidebar topology against existing
   identities, kinds, splits, folders, lock grants and stashed shapes directly.
   Cache misses retain the existing construction and authorization rules. This is
   still a linear validation, not a constant-time revision cache.
3. **Composite small decorations.** A row-sized CALayer handles highlight opacity
   fades, and two tiny layers draw the loading track and animate its fill. The
   compositor owns the interpolation between state updates. Text, editors,
   keyboard targets and accessibility stay in the original SwiftUI hierarchy.
   Favourite/row morphs retain their existing renderer. Reduce Motion and Battery
   Saver finish the compositor animations immediately.

Full row-host rasterization is deliberately excluded: these owners span the
entire logical sidebar document, even when only a few controls are attached.
Flattening them could allocate very large textures. The experiment does not use
global `drawingGroup`, asynchronous drawing, or a permanent display-link loop.

## Compare the same binary

From this worktree on an unlocked Mac:

```sh
./scripts/render-experiment.sh baseline /tmp/vane-render-baseline
# Quit the synthetic app or press Ctrl-C in its supervising terminal.
./scripts/render-experiment.sh all /tmp/vane-render-all
```

The launcher opens real Wikipedia, GitHub and MDN pages by default. Override them
with repeated `--website URL` arguments. Tabs, Spaces and history metadata are
seeded only to provide a reproducible population; page content comes from the
actual sites through WebKit. The isolated profile has no signed-in accounts.

The existing supervisor creates a uniquely signed app and independent test data.
It records the actual sites, flags, PID, executable, bundle, start time and
resource samples, and verifies its owned app exits. It does not use the normal
Vane profile. Evidence directories must be new; keep them for comparison.
Use `signals`, `topology`, or `layers` to attribute each candidate separately.
Keep window sizes, display refresh, motion policy and interaction sequence equal.

The corresponding environment flags are `VANE_RENDER_EXPERIMENT=1`, with
`VANE_RENDER_SIGNALS=0`, `VANE_RENDER_TOPOLOGY=0`, or `VANE_RENDER_LAYERS=0` as
independent opt-outs. They are captured per process and never saved to preferences.

## Verification and measurements

```sh
VANE_RENDER_EXPERIMENT=1 python3 scripts/run-native-tests.py -c release -j 4 \
  -Xswiftc -enable-testing --filter \
  'RenderPerformanceExperimentTests|Feel02SidebarTests|SidebarObservationTests|SidebarHoverLayoutTests|TabTooltipTests|NativeSidebarMotionTests|SearchTypingTests'
VANE_RENDER_BENCHMARK=1 python3 scripts/run-native-tests.py --skip-build -c release \
  --filter RenderPerformanceExperimentTests
# Real-page comparison; repeat with the experiment set to 1, and with each site:
VANE_UI_PERFORMANCE=1 VANE_RENDER_EXPERIMENT=0 \
  VANE_LIVE_SITE_URL='https://en.wikipedia.org/wiki/Swift_(programming_language)' \
  VANE_LIVE_SITE_EXPECTED_TITLE=Swift \
  python3 scripts/run-native-tests.py --skip-build -c release \
  --filter LiveSidebarResponsivenessTests
```

The diagnostic compares both topology algorithms in one process, at 28, 300 and
1,000 tabs. Notification counts distinguish avoided work from elapsed-time noise.
Neither metric establishes displayed FPS. Before promoting a candidate, compare
SwiftUI update causes, CPU time, GPU/render time, physical footprint and actual
presented-frame tails on the same physical display. Use the recorder and analyzer
described in [Development](DEVELOPMENT.md), and verify native controls, light/dark
appearance, rename, scroll, Space transitions and both motion policies.

Do not claim 120 FPS from a 60 Hz session, a main-thread heartbeat or compositor
submission counts. There are no new wall-clock CI thresholds.

## Initial results — October 26, 2026

Release builds on the development Mac, Xcode 27 / macOS 27:

| Diagnostic | Legacy | Experiment |
| --- | ---: | ---: |
| Whole-tab notifications from 200 progress/hover updates | 200 | 0 |
| 1,000 cache hits, 28 tabs (median of five batches) | 9.97 ms | 9.15 ms |
| 1,000 cache hits, 300 tabs | 83.80 ms | 77.75 ms |
| 1,000 cache hits, 1,000 tabs | 268.77 ms | 250.19 ms |

This measures signal fanout and cache lookup work, not frames. The first cache
prototype repeatedly invoked observable collection getters inside the loop and
was substantially slower. Capturing their existing COW storage once corrected the
regression. One earlier diagnostic overlapped a pure validation run and is excluded;
the table uses the subsequent serialized diagnostic. The 1,000-tab legacy batches
included outliers up to 480 ms, so these medians are diagnostic, not universal gains.

Focused release validation in both modes passed 65 tests with one opt-in diagnostic
skipped and no failures. The explicit diagnostic also passed all seven tests.
The pure selfcheck and six Python launcher/URL-isolation checks passed. Independent
review found appearance and launcher-flag issues; both were corrected and reviewed
again with no remaining actionable findings.

The earlier local-page display-callback comparison was mixed and does not establish
a general FPS gain. Real-page comparisons are recorded separately; neither display
callbacks nor submitted compositor transactions establish presented-frame FPS.
