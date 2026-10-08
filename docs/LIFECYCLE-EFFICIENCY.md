# macOS 27 lifecycle investigation

Test host: macOS 27.0.1 (26A434), Apple silicon, logged-in desktop, ad hoc signed
sandboxed debug fixture with a fresh Downloads-scoped data directory. Measurements
are local evidence; other Vane development/build tasks were running on this Mac.

## Confirmed ownership and work defects

- `Tab.tearDown()` stopped the WebKit page but retained `existingWeb` on a closed row.
- `Tab.release()` detached a page without removing the strong `WebHost.web` and
  `recent` cache references. Cache cleanup required another SwiftUI render.
- Cached palette tab/report callbacks retained closed stores through SwiftUI state.
- Main-menu action targets also accumulated across every rebuild.
- Little Vane Space menu actions accumulated in a static array and retained their
  `TabStore`, its closed tab, and its WebView indefinitely.
- Suspension retained MediaState document reports (`WKFrameInfo`) and playback flags.
- The app-wide suspension timer and memory-pressure source continued after the last
  store closed. A regression verified they now stop and restart with store ownership.

Closure now drops the page, host cache, KVO, script handlers, document media reports,
PiP registrations/captures and controls. Representable dismantling drops its host's
cache. Menu items retain their own action targets for exactly the menu's lifetime.
Palette tab/report actions refer weakly to the tab/store; they act while the window
is alive and do nothing once those owners are gone. Little Vane closes its palette
and cancels pending suggestions, and SwiftUI owns its focus subscription.
Queued script messages from a released WebView cannot recreate a page or media state.

The signed WebKit regression reproduced loss of a real draft under critical memory
pressure. Pressure now checks forms and revalidates policy/selection/page identity
after its awaits. Both paths retain media/PiP protections and reject stale results
when a WebView or URL changes. A failed form query conservatively preserves the page.

## Measurement procedure

Run a built executable in a signed, isolated fixture:

```sh
swift build -c debug
python3 scripts/check-browser-smoke.py --lifecycle
```

The fixture warms WebKit and Little Vane chrome, measures parent resident memory,
closes 100 loaded tab pages and 100 loaded Little Vane windows (building a Space menu
for each), restores 200 pinned parked session entries, closes those rows, waits at
least 30 seconds, counts weak survivors and measures idle parent CPU for at least
60 seconds. It prints actual settling/sampling durations, bundle paths, PIDs and
process start times. A timeout terminates only the unreaped owned child. A separate
tracked process unregisters the isolated WebKit data store after browser exit.

RSS is measured with `MACH_TASK_BASIC_INFO`, CPU with `getrusage(RUSAGE_SELF)` divided
by monotonic elapsed time (100% means one CPU core). The memory limit is the larger
of 50,000,000 bytes and 10% of the warmed baseline. WebKit helper process RSS/CPU and
system energy/wakeups are excluded from these counters.

The initial baseline fixture called the tab teardown primitive directly; the final
fixture uses the TabStore close path. Both use actual Little Vane window closure.
The initial 200 parked rows were created directly; the final fixture uses session
restoration. These differences make the ownership comparison useful but the memory
numbers an approximate before/after comparison, not a controlled benchmark.

## Baseline evidence

At the starting revision `aaa3d56`, the first ownership regressions failed as
expected. A separate real-WebKit regression also failed because a suspended page's
media report remained present.

| Baseline metric | Observed |
| --- | --- |
| Warm parent RSS | 131.28 MiB |
| Parent RSS after settling | 191.12 MiB |
| Growth | 59.84 MiB (exceeds 50 MB) |
| Closed WebViews still alive | 100 / 200 |
| Closed Little Vane stores still alive | 100 / 100 |
| Closed Little Vane windows still alive | 0 / 100 |
| Idle parent CPU | 0.035% over 93.5 seconds |
| 200 parked rows | 0 WebViews |

The global menu action array explains all 100 retained Little Vane stores and their
closed WebViews. The baseline passed the parent idle CPU threshold already; this
work should not be described as a measured CPU reduction or battery-life gain.

## Post-fix evidence

After the palette ownership fix, the signed cycle fixture reported zero closed
WebViews (0/200), windows (0/100) and stores (0/100); the suspension timer was stopped.
Its warmed RSS was 136.55 MiB and settled RSS was 149.08 MiB, a 12.53 MiB increase,
below the 47.68 MiB (50 MB) threshold. Settling took 30.14 seconds; idle parent CPU
was 0.024% over 61.3 seconds. This run preceded the separate main-menu target fix.

The final code also passed under Instruments Time Profiler: 139.44 MiB warmed RSS,
168.86 MiB settled RSS (29.42 MiB growth), zero closed views/windows/stores, zero
WebViews for 200 restored parked entries, and no suspension timer. Settling took
31.86 seconds; idle parent CPU was 0.010% over 60.9 seconds. Instrumentation adds
overhead, so this is a separate successful target check rather than a directly
comparable RSS benchmark.

The full XCTest run passed 502 tests with one opt-in Keychain test skipped, before
the final palette/menu changes. Subsequent focused runs cover the final changes,
including real media/PiP, Battery Saver, shared presentation and palette/search behavior:
61 focused tests passed on the final code. The final debug build and pure selfcheck
passed. Signed WebKit smoke passed 195 assertions on the final code, including
critical-pressure draft preservation.
Two stale sidebar expectations from before PR #319 were corrected to its documented
window-wide visibility behavior; no sidebar implementation was changed.

Instruments Time Profiler captured all 100 tab and 100 Little Vane cycles plus the
200-row restore and settling/idle intervals on the final code; the app exited with
a passing result. An earlier trace showed the palette-store retention subsequently
fixed. Allocations launch stalled
in `liboainject.dylib` before application startup, verified with `/usr/bin/sample`; the
tracked launch was terminated (TERM, then KILL after identity checks) and exited.
This is an Instruments startup limitation, not a successful allocation/leak profile.

## Scope and limitations

The fixtures use tiny local HTML and parked session rows, not 200 simultaneous heavy
live websites. Resident-memory noise, App Nap, compression and WebKit process reuse
make a single local run insufficient for a battery-life claim. Instruments allocation
and energy profiling, helper process accounting, real streaming/WebRTC/device sessions,
long-duration browsing, macOS 26 and notarized release coverage require separate evidence.

The guarded WebKit `_close` SPI remains for prompt page/process shutdown and still has
an about:blank fallback. Retitle tasks intentionally finish one bounded 150 ms history
write after closure; they do not retain the tab and are not recurring timers. Battery
power notifications and MediaState's single app-wide audio hook have app lifetime.
Live Folders stops its timer when its profile has no browser owners. Little Vane's
focus notification uses a SwiftUI-managed subscription; the cycle fixture checks
that its stores and windows disappear. Peek explicitly removes its resize/close
notifications when dismissed. Existing draft detection covers main-frame inputs and
contenteditable elements; iframe/shadow-DOM/JavaScript-only drafts remain a limitation.

Asynchronous suspension probes guard WebView and URL identity, but do not yet use
a document-generation token for a same-URL reload. That pre-existing race needs a
controlled regression fixture before broader navigation/draft claims.
