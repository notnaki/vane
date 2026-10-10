# Injected script investigation — 2026-10-09

Baseline: `f24aa5f`. Apple M1 Max, macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Swift 6.4. The changes affect script production only; WebView
configuration and native frame/origin validation are unchanged.

## Method

A standalone AppKit/WebKit probe loaded the exact production script strings into
visible 800 × 500 nonpersistent web views. Each script received a fresh document:
10,000 section/span pairs, a link, and a username/password form. Scripts used their
production start/end timing. The attribution probe ran each script separately in
the page world; the committed diagnostic uses each production content world.

The shared `/tmp/vane-performance-window.lock` serialized the measurement window
with the startup, sidebar, History, lifecycle and webpage tasks. No competing
agent builds/tests ran during the accepted measurements. Existing user apps were
left running. Sources were retained to compare baseline and candidate with the
same probe, DOM, viewport, workload and instrumentation.

Instrumentation counted selectors, computed-style reads, messages, timers and
synchronous script callback elapsed time. Times are diagnostics from one broad
before/after pass, not a CPU percentage or a statistical latency guarantee. The
WebKit clock had millisecond granularity: a recorded zero is not zero CPU usage.
Waits are excluded from callback time. No wall-clock performance limit is added
to routine CI.

## Results and fixes

| Workload | Baseline | After |
| --- | --- | --- |
| Zap, ten moves over an ID-less span among 10,000 siblings | 2,817 ms callback time; ten selector searches | 0 ms recorded; no selector searches |
| Tab audio, 500 volume events after dynamic player insertion | 153 ms callback time; 504 searches including queued discovery | 2 ms; no searches |
| 100 mutation microtasks after mute then unmute | 100 observer callbacks and 100 subtree searches | No observer callbacks or searches |
| Muted tab, 100 mutation microtasks starting with a nested player | 104 searches | One subtree search; the queued reconciliation covers later mutations |
| 1,000 brief link enter/leave cycles plus scrolling | 1,000 preview cancellation messages; 14 ms callback time | No messages; 4 ms |

An initial 1,000-move Zap stress attempt monopolized its WebContent process and
was stopped using the recorded probe PID/start time. It is excluded from timing
comparisons. The bounded ten-move baseline and after-run above both completed.
All tracked probe processes exited. No regular Vane app was quit or modified.

Zap now checks element eligibility and geometry on movement, building the unique
selector only when clicked. The click still validates the current DOM path,
including duplicate IDs, and rejects shadow content, detached nodes and browser
overlays. No selector cached during hover can target a replacement element.

Tab audio uses live video/audio collections instead of querying the whole DOM
on each event, preserving document order for equal-volume players. Its fallback
mute observer disconnects and cancels pending work when unmuted; muting again
reinstalls it. Once reconciliation is queued, later mutations do not repeat
subtree discovery. Nested replacement players still inherit mute. The existing
250 ms fallback window is preserved.

Preview cancellation is sent only after a preview request was announced. A dwell
that was canceled before its request never entered the native request pipeline.
Announced previews still cancel on leave, scroll, blur, navigation and modifier
changes, and Shift still requests immediately. The native preview lifecycle work
is coordinated separately with the lifecycle task.

## Other findings and limitations

- All seven measured scripts had no callbacks, timers, searches or messages in
  their settled 500 ms idle sample. This does not establish behavior of arbitrary
  site scripts, extensions, embedded providers, or long idle sessions.
- Autofill's 30 unrelated mutation bursts coalesced to eight discovery timers,
  16 queries and 4 ms baseline / 3 ms after callback time. Twenty dynamic form
  mounts/focuses/removals used 203 queries, 32 messages and 18 / 13 ms. No autofill
  optimization was justified by this fixture; its safety/visibility checks remain.
- Media Session/player reporting used zero document searches across 500 metadata
  events. Draft protection used 30 subtree searches and 0–1 ms across the 30
  ordinary mutation bursts. Large editable registries, deep trees, shadow editors
  and provider-specific media remain separate stress cases.
- Status hover emitted the expected enter/leave changes (2,000 messages for
  1,000 complete cycles). Ordinary scroll events did not produce preview or
  password messages when no relevant UI was open. No idle polling or duplicate
  installation was found in the Engine/controller trace. PiP discovery scans
  happen at installation or explicit player commands; its listeners are delegated.
- Enabled Boost text scaling remains expensive on very large pages: 30 additions
  triggered 318,585 computed-style reads and 613 / 611 ms of callback work. The
  current full remeasurement preserves inheritance and dynamic CSS relationships.
  An incremental rewrite needs separate correctness fixtures; this change does
  not speculate about safe caching or weaken that behavior.
- Synthetic pointer events isolate script cost; these results are not an
  end-to-end native input or full-browser frame-rate claim. No credentials, user
  profiles, network pages, or persistent stores were used by the attribution probe.
  Reduce Motion, Battery Saver, accessibility, native media controls, autofill
  origin/target checks and user data paths are unchanged.

## Repeat and validate

Run the same diagnostic harness at both revisions on a quiet logged-in Mac,
keeping the harness identical when testing an older source revision:

```sh
VANE_PAGE_SCRIPT_PROFILE=1 swift test --filter PageScriptPerformanceTests/testInjectedScriptDiagnostics
```

Normal focused correctness/work-count checks:

```sh
swift test --filter 'PageScriptPerformanceTests|SiteBoost.*Tests|PasswordAutofillTests|PasswordOriginTests|MediaControlsWebKitTests|DraftProtectionTests'
./.build/debug/vane selfcheck --pure
```

The regressions assert work counts and real WebKit behavior: unmute/re-mute with
nested players, coalesced discovery, event reporting without document searches,
Zap picking after a path changes, duplicate IDs, and brief versus announced
preview cancellation. Existing password, Boost, draft and media fixtures cover
the combined installed scripts and their security/lifecycle boundaries.
