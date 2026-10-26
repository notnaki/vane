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
4. **Narrow selection and rename observation.** Structural owners ignore row-only
   mutations. Lightweight row controls observe the affected selection, split and
   rename state; title/editor surfaces keep their own narrower subscriptions.
   Full pane metadata notifications and replacement-object rebinding remain live.
5. **Defer unchanged detached row roots.** Mounted roots still refresh. Detached
   hosts retain their current root only while entry, depth, position, population
   and Tab object identity match; the latest root is installed before reattachment.
   Protection and membership changes sanitize immediately.
6. **Keep panel geometry stable.** Preserve the existing native translation path
   and carry its actual presented position into interrupted gestures. Eligible
   programmatic shrinking transitions briefly hold WebKit width, then apply the
   settled width. Growing pages, live window resize, inspector layouts, ownership
   changes and reduced motion keep or restore normal autoresizing.
7. **Pause hidden Library work.** Cancel archive filtering, thumbnail requests and
   rail prewarming while hidden, and avoid downloads/media regrouping. Retained
   content refreshes before interaction on exposure. Work stays admitted through
   the closing animation; reopening cancels pending deactivation. Catalog
   preparation stays live because it determines panel width.

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
Use `signals`, `topology`, `layers`, `selection`, `hosts`, `panels`, `viewport`,
or `hidden` to attribute each candidate separately.
Keep window sizes, display refresh, motion policy and interaction sequence equal.

The master flag is `VANE_RENDER_EXPERIMENT=1`. Independent opt-outs are
`VANE_RENDER_SIGNALS=0`, `VANE_RENDER_TOPOLOGY=0`, `VANE_RENDER_LAYERS=0`,
`VANE_RENDER_SELECTION=0`, `VANE_RENDER_HOST_REUSE=0`,
`VANE_RENDER_PANEL_MOTION=0`, `VANE_RENDER_VIEWPORT=0`, and `VANE_RENDER_HIDDEN=0`.
Flags are captured per process and never saved to
preferences.

## Rejected candidate

A bounded compositor grain texture was evaluated and removed. Although it
reproduced a detached CGContext reference, strict comparisons with the actual
mounted legacy NSView failed at both 1x and 2x. The existing native grain renderer
remains unchanged; no grain performance gain is claimed. Diagnostic logs and
images were retained locally under `/tmp/vane-render-expanded-final-tests.log`
and the development Mac's temporary `vane-grain-parity` directory. The candidate
source and tests were preserved as `/tmp/vane-grain-rejected-{source,tests}.swift`.

## Verification and measurements

```sh
VANE_RENDER_EXPERIMENT=1 python3 scripts/run-native-tests.py -c release -j 4 \
  -Xswiftc -enable-testing --filter \
  'RenderPerformanceExperimentTests|RenderSurfaceActivityTests|NavigationViewportDeferralTests|SidebarSelectionObservationTests|NativeSidebarHostReuseTests|LibraryHiddenSurfaceTests|LibrarySwipeTests|Feel05ThumbnailTests|SidebarObservationTests|KeyboardAccessibilityTests'
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

The initial three-candidate version also passed six real-site runs: Wikipedia,
GitHub and MDN, each with 28 and 300 seeded tabs, a matching live host/title, and
nonempty remote document content. The 300-tab sidebar callback p95 was mixed:

| Real page | Legacy | Initial experiment |
| --- | ---: | ---: |
| Wikipedia Swift article | 9.35 ms | 11.54 ms |
| Vane GitHub repository | 9.98 ms | 11.37 ms |
| MDN JavaScript | 10.18 ms | 10.21 ms |

These single A/B runs show no consistent general improvement. They measure
display-callback cadence, not presented-frame FPS; larger populations still had
long stalls. The expanded candidates above require their own combined validation
and attribution before promotion. Raw initial logs were retained under
`/tmp/vane-render-real-sites-20261026` on the development Mac; this temporary path
is local evidence, not a portable benchmark archive.

## Expanded validation

The retained eight flags passed 310 broader release tests, with four skipped and
no failures. A final focused run passed 116 tests with two opt-in diagnostics
skipped; the same 116-test selection passed in legacy mode, with six experimental
or diagnostic checks skipped. The pure selfcheck and six Python launcher checks
also passed. Every native wrapper verified host exit and backend cleanup.

Mechanism checks demonstrate that unrelated mounted rows avoid selection redraws,
unchanged detached roots avoid replacements, and ten shrinking host-width changes
produce one WebKit width update at rest. Hidden archive queries and download
thumbnail requests remain unadmitted until exposure; queued thumbnail work is
cancelled when hidden. Closing retains admission through the bounded animation
tail, and reopening rejects the old completion. Battery Saver exercises immediate
policy cancellation; system Reduce Motion is source-reviewed rather than changed
by the test harness.

Native keyboard tests passed. Two broader native AX parity checks were skipped
because their unbuffered AX route or external controller was unavailable; full
VoiceOver traversal parity is unverified. The other skips are opt-in timing
diagnostics. Independent reviews found closing-tail and hidden-download-thumbnail
gaps, both corrected and re-reviewed with no remaining actionable findings.

## Expanded real-site comparison

All three real websites passed in both modes at 28 and 300 tabs. Original baseline
samples overlapped compiler activity and were excluded. Quiet repeats were admitted
only after process-activity checks; an additional GitHub repeat was also excluded.
Remote documents were checked for the requested host, expected title and nonempty
body. Native test hosts and their WebKit stores retired successfully after each run.

| 300-tab sidebar callback p95 | Legacy | Eight flags together |
| --- | ---: | ---: |
| Wikipedia Swift article | 9.31 ms | 10.59 ms |
| Vane GitHub repository | 9.29 ms | 10.53 ms |
| MDN JavaScript | 9.73 ms | 11.18 ms |

The combined preset was about 13–15% worse on this diagnostic. Median callback
intervals stayed near 8.33 ms, and both modes still had long 113–140 ms tails.
These are individual admitted comparisons, not a statistical or presented-FPS
claim. Reduced mechanism work has not established better overall smoothness.
Keep the master flag off for ordinary use; `all` exists for comparison, not as a
recommended fast preset. Per-flag attribution is recorded separately.

Raw expanded evidence is local to `/tmp/vane-render-expanded-real-20261026`,
including accepted log identities, rejected samples and activity observations.

## Individual flag diagnostic

Each flag was also attempted independently against the live Wikipedia page, with
legacy runs before and after. Clean 300-tab callback p95 samples were:

| Mode | p95 |
| --- | ---: |
| Legacy before | 9.99 ms |
| Topology only | 9.57 ms |
| Decoration layers only | 10.55 ms |
| Selection observation only | 9.46 ms |
| Viewport only | 9.93 ms |
| Hidden work only | 10.65 ms |
| Legacy after | 9.98 ms |

Topology and selection are promising in this single diagnostic; decoration layers
and hidden-work admission did not improve this scroll sample. The test does not
exercise every candidate's intended workload equally. Signals, native host reuse
and panel-only timings remain unverified: both bounded attempts were excluded
for competing activity or visibility prerequisites. One host run skipped before
its 300-tab sample after losing visibility; its repeat passed functional checks
but had competing activity. No rejected result is treated as an FPS measurement.

These are isolated diagnostic runs, not evidence for shipping defaults. Raw logs,
flag values, activity checks and admission decisions are retained locally under
`/tmp/vane-render-attribution-20261026`.
