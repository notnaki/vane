# Development

[Documentation index](README.md) · [Project README](../README.md)

Use focused validation for the affected behavior. Documentation-only changes need link,
command-reference, and diff checks; they do not need the full local application suite.
Required PR CI still applies.

## Setup and local builds

Requires macOS 26 or later and Xcode 26 or later with its Swift toolchain. Location
decisions use WebKit’s compatibility delegate on macOS 26; Xcode 27 builds also compile
the public macOS 27 delegate, with runtime availability checked.
Confirm the selected toolchain with `xcodebuild -version` and `swift --version`.

```sh
git clone https://github.com/notnaki/vane.git
cd vane
./make-app.sh debug
open Vane.app
```

For an optimized build, run `./make-app.sh` (release is the default). The script builds
the executable, installer and icon XPC services, resources, and icon assets, then signs
the app ad hoc unless `SIGN_ID` is set. It replaces the generated `Vane.app` in this
checkout. No package dependency installation is required.

To build only the executable:

```sh
swift build -c release
./.build/release/vane selfcheck --pure
```

Use the assembled bundle for icons, sandbox/signing behavior, and native app checks.
Local builds skip the startup default-browser prompt; **Make Vane Default…** remains
available in Settings. Distribution instructions are in [Releasing](RELEASING.md).

## Command line

The executable is `.build/release/vane` after `swift build -c release`. These examples
use `vane` as shorthand for that path.

| Command | Result |
| --- | --- |
| `vane` | Open the browser, restoring the last session when enabled. |
| `vane https://example.com` | Open a URL in the browser. |
| `vane selfcheck --pure` | Run checks that need neither a keychain nor a window server. |
| `vane selfcheck` | Run the full local checks, including keychain and WebKit checks. |
| `vane browsercheck` | Run real WebKit checks inside a signed, isolated app bundle; use the smoke-test script below. |
| `vane import passwords.csv` | Import a browser password CSV into the login keychain. |
| `vane drmcheck` | Probe which encrypted-media key systems WebKit can initialize. |
| `vane drmcheck <url>` | Check decoded playback progress and report whether modern media keys are attached. |

`browsercheck-cleanup` unregisters the isolated store identified by a browser-check
fixture. Use it only with that fixture’s recorded identity; do not point it at a regular
profile. Password-import format, duplicate, and partial-failure rules are in [data
imports](DATA-AND-PRIVACY.md#imports-and-exports).

## WebKit and protected media

Vane uses the system WebKit engine rather than bundling Chromium. `drmcheck` tests the
encrypted-media path available to the current macOS WebKit build. A successful
key-system probe does **not** guarantee that a particular streaming service will play:
the service, account, license exchange, and playback still need a real-site test.
`drmcheck <url>` checks playback progress on a page you provide.

## Testing

The project has one Swift executable target, an XCTest target, and inline checks run
through `selfcheck`. Use the [contributor guide](../CONTRIBUTING.md) to choose focused
local validation. Required PR CI still applies before merging.

### CI overview

CI first checks the diff. Root Markdown files, Markdown under `docs/`, and Markdown
issue/PR templates take the documentation-only path: diff checks and the final
`checks` gate, without macOS builds or native tests. Other configuration files
take the full path, as do mixed changes and missing comparison history. The classifier is [`scripts/ci-change-scope.py`](../scripts/ci-change-scope.py).

For app changes, one debug build compiles the app and test bundle and assembles
`Vane.app`. Four native runners and a separate packaging runner reuse a runtime-only
artifact, verifying its revision, checkout path, and Swift toolchain before execution.
Object files and compiler caches are excluded from that transfer. Source fixtures
and shared runtime checks each run once; separate desktops keep packaging work away
from native UI tests. The required `checks` gate requires every applicable required
job to succeed; the named worker-UA advisory job is excluded. Jobs intentionally skipped for documentation-only changes are handled by
the gate's documentation path.

Only the build job restores the Swift debug cache; successful `main` builds save it.
The cache is keyed by macOS architecture, Swift/Xcode/SDK versions, and package/source
hashes. Content-matching timestamps allow unchanged files to stay incremental, while
SwiftPM still validates the build. Successful aggregate checks retain the two newest
Swift debug caches. Superseded runs on the same branch or PR are cancelled. The release
workflow builds and smoke-tests the optimized app separately; its products are never
cached because they can contain the OAuth secret.

### Native fixture execution

Use the wrapper for full native validation on a logged-in macOS desktop:

```sh
python3 scripts/run-native-tests.py --jobs 1
```

CI runs four groups on separate macOS runners, keeping each test class together
and each runner's UI tests sequential. `swift test list --skip-build` supplies the
complete inventory; `scripts/native-test-shards.py` balances classes using advisory
durations in `scripts/native-test-durations.json`, assigns new classes automatically,
and verifies every selected required test completed. The single known worker-UA
probe runs on a separate advisory runner. Each required group runs its own startup
preflight and cleanup, and all four must pass the required `checks` gate.
Same-desktop `--parallel` execution remains unsupported because UI fixtures share
focus and application state. Duration estimates affect balancing only, never coverage.

The wrapper passes its arguments to the complete `swift test` command; focused runs
can add `--filter 'PasswordAutofillTests|SavedReaderTests'`. After the test host exits,
it starts the same test bundle in a fresh process to delete only the exact owned
WebKit stores recorded by those fixtures and verifies their absence. Cleanup runs
even when the primary tests fail, and a cleanup failure fails an otherwise passing
run. An unverified cleanup keeps its private manifest and reports its path.
The post-exit retirement phase has a 60-second budget for all owned IDs; its fresh
driver has a 90-second ceiling. These bounds do not alter primary fixture deadlines.

Direct `swift test` remains supported and performs the existing immediate cleanup.
The wrapper defers destructive WebKit cleanup for shared-helper-owned normal profiles;
it does not change test assertions, original fixture deadlines, or product behavior.

### Client certificate fixture

`swift test --jobs 1 --filter ClientCertificateTests` checks identity eligibility,
selection, cancellation, and profile/private/session boundaries with generated
identities imported into memory only. `python3 Tests/ClientCertificates/fixture.py`
compiles the authentication core and tests a generated three-tier client chain
against a local TLS server that trusts only its root. It needs no window server or
user keychain changes and removes its generated keys and server on exit. Add
`--rollover` to exercise a same-subject CA rollover with a partial local chain.
`swift test --jobs 1 --filter ClientCertificateChallengeTests` needs a window server
and checks the native chooser, cancellation, navigation, and tab closure using an
injected provider of generated in-memory identities.

### Routine CI commands

The `Known limitation — extension worker UA (advisory)` job separately runs
`ExtensionUserAgentTests.testKnownServiceWorkerUserAgentLimitation`. Manifest-v3
workers can expose WebKit's engine UA instead of the selected page UA; this known
fault currently does not block merges. The probe keeps its desired-behavior
assertions and uploads the result and cleanup log. Required shards still cover
popup UA, manifest-v2 background UA, profile storage isolation, and controller
ownership. The planner checks that the exact advisory probe exists and that the
required/advisory test sets partition the discovered inventory without overlap.
An unfiltered local native run includes the probe and can fail on this known fault.

These commands cover the app checks used in CI. For routine changes, select only
the checks relevant to the affected behavior:

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
scripts/check-webkit-startup.sh
python3 scripts/run-native-tests.py --jobs 1
scripts/check-app-icons.sh
scripts/check-cloud-ai.sh
bash scripts/test-cli-import.sh .build/debug/vane
python3 scripts/test-ci-source-state.py
python3 scripts/test-release-workflow.py
./make-app.sh debug
python3 scripts/test-default-browser-prompt.py
./scripts/test-build-dmg.sh
bash scripts/test-update-installer.sh Vane.app --unsigned
scripts/test-updater-recovery.sh
python3 scripts/test-updater-transport.py
scripts/test-updater-relaunch.sh
```

### Password fixtures

For focused password validation on a logged-in macOS desktop:

```sh
VANE_TEST_KEYCHAIN=1 swift test --filter Password
python3 scripts/check-browser-smoke.py
```

The autofill fixtures exercise real WebKit documents, controlled input events, dynamic
visibility, account continuity, embedded forms, stale chooser targets, and scoped
Keychain reads. Additional fixtures cover save review, rejected submissions, generator
options, Keychain failures and identity collisions, and clipboard ownership. The signed
smoke also verifies fresh-process Keychain persistence and deletion. Keychain-dependent
XCTest fixtures report a skip if storage is unavailable. See [Password manager](PASSWORD-MANAGER.md)
for the precise boundaries and remaining real-site/device validation.

### Website popup fixtures

```sh
swift test --filter 'WebsitePopup|SignInCompatibility|NavigationWebKit|LinkInteraction|LittleArcSpaceMenu|KeyboardAccessibility|PasswordChooser'
```

These local WebKit fixtures cover temporary dialog windows, opener messaging, blank
popups written by their opener, cross-origin redirects, private cookies, manual cancel
and retry, script close, nested lifetimes, ordinary blank-target tabs, password UI and
text-entry shortcuts. They do not establish Google or Reddit service acceptance.

### Specialist reliability fixtures

For opt-in cold/warm startup, large-session restoration and parked/sleeping tab
measurements, see [Startup performance](STARTUP-PERFORMANCE.md). Build first and
reserve a quiet profiling window before collecting timings.

For site-permission lifecycle fixtures and a fake display-capture check, see
[Site permissions on macOS 26 and later](SITE-PERMISSIONS.md#validation-and-remaining-platform-coverage).

For download interruption, resume, destination and process-restart fixtures, see
[Download reliability on macOS 27](DOWNLOAD-RELIABILITY.md).

For navigation identity, history, cancellation, form resubmission and local WebKit
fixtures, see [Navigation correctness on macOS 27](NAVIGATION-RELIABILITY.md).

`swift test` covers search typing and cancellation, link gestures and previews, Space
switching and deletion, tab ordering, Battery Saver, media permission popups and grant
lifetimes, requesting-frame ownership and synthetic capture revocation, Easels, page
capture, and other browser UI behavior. Search fixtures include a large history
database, keyboard selection, live history changes, and private windows.

### History performance budget

The native History rendering performance budget is a separate, opt-in release benchmark
on a quiet logged-in Mac. It retains its 100 ms limit; hosted debug CI cannot separate
Vane work from window-server activation and timer scheduling. History correctness,
profile isolation, search cancellation and input-thread search checks remain in the
routine test suite.

```sh
VANE_UI_PERFORMANCE=1 swift test -c release -Xswiftc -enable-testing --filter HistoryResponsivenessTests
```

Store, bookmark presentation/filtering, Library filtering, cancellation drain, and
repeated session-write measurements also have an opt-in release fixture. It uses
isolated synthetic profiles (10,000/240,000 visits and 1,000/10,000 displayed
bookmarks) and prints measurements without machine-sensitive timing assertions:

```sh
VANE_STORE_PERFORMANCE=1 swift test -c release -Xswiftc -enable-testing --filter StoreLatencyBenchmarks
# Native search-field focus, including empty and superseded queries:
VANE_STORE_PERFORMANCE=1 swift test -c release -Xswiftc -enable-testing --filter BookmarkPresentationTests
```

The Library swipe fixture uses 300 tabs and 2,000 archived entries to report first-update
and subsequent native layout costs, browser invalidations, and window visibility. Forced
layout can run with an occluded test window; these numbers measure main-thread update
work, not displayed frame rate. Set `VANE_LIBRARY_PERF_TABS` to compare other sidebar sizes.

```sh
VANE_UI_PERFORMANCE=1 swift test --filter LibrarySwipeTests.testPopulatedArchiveSwipeTiming
# Small-sidebar Library and Space swipe comparisons:
VANE_UI_PERFORMANCE=1 VANE_LIBRARY_PERF_TABS=10 swift test --filter 'LibrarySwipeTests.testPopulatedArchiveSwipeTiming|SidebarViewportPerformanceTests.testSpaceSwipeLayoutTiming'
```

`SidebarViewportPerformanceTests` also guards viewport-only row mounting, saved
scroll offsets, access to the last row, and bounded production tab controls while scrolling.
For a 300-tab vertical scroll comparison in both directions:

```sh
VANE_UI_PERFORMANCE=1 swift test --filter SidebarViewportPerformanceTests.testPopulatedSidebarScrollTiming
```

This reports median, p95, and maximum forced layout cost. Layout work under 8.33 ms leaves CPU
headroom for a 120 Hz display; these timings do not establish displayed frame rate.

For the smaller sidebar path, the 22-tab retention fixture checks a seven-tab folder,
hidden input anchors, row spacing, and control reuse while scrolling. The opt-in run
also reports scroll layout timings:

```sh
VANE_UI_PERFORMANCE=1 swift test --filter SidebarRowRetentionTests
```

Sidebars with at most 40 tabs and folders retain unlocked row controls between disclosure
changes. Larger outlines keep viewport-only mounting. This fixture uses parked local pages;
use the affected profile and active website as well when investigating reported stutter.
The native-host regression
`SpaceNativeRenderingTests.testFolderDisclosureDefersHiddenSpacePreparationAndDisposal`
uses the reported 26-tab outline with adjacent Spaces. It checks that hidden preview
hosting trees are retired and rebuilt after folder disclosure settles, rather than
competing with the input or animation frames.

Search opening and typing diagnostics use the production native browser window with
20 and 300 parked tabs. They report forced opening layout, the largest 2 ms input
heartbeat gap during opening, and worst native field-edit/layout cost, without a CI
timing limit. Hidden adjacent Space preview preparation must stay paused until search
closes and its dismissal fade finishes.

Unchanged prepared sidebars survive search presentation, suggestion updates, and vertical
scrolling. A claimed Space surface updates its outgoing native scroll viewport before
travel; structural changes and folder-protection revocation still invalidate immediately.
Hiding the sidebar suspends its gesture input and keeps valid hidden captures. Revealing
it validates their geometry after travel; profile/window teardown releases them fully.
The tab, folder, split and favourite row hierarchy observes `SidebarObservation`, which
forwards structure, selection, rename and protection changes synchronously. General
window visibility and search publications do not invalidate that entire hierarchy.
`SidebarObservationTests` verifies both the publication boundary and mounted-view updates.
`SpaceNativeRenderingTests` checks cache identity across search/scroll, the actual native
scroll position, rapid profile reversals, and synchronous protection invalidation. Visible
animation fixtures activate their test window and restore the prior activation policy.

```sh
VANE_UI_PERFORMANCE=1 swift test --filter SearchPresentationPerformanceTests
```

`LiveSidebarResponsivenessTests` mounts the production browser host with three loaded
WebKit documents, a selected page in the content card, and 47 archived entries in the
closed Library. Its normal run serves a
150-card HTML document over local HTTP and checks that folder disclosure, search edits,
and tab selection preserve the page and its input. Timing runs compare 28- and 300-tab
outlines through native scroll events and AppKit's normal display cycle, without forcing
whole-window layout on each input. They check that events reach the intended list, keep
vertical scrolling out of Space navigation, and report input admission separately from
field readiness and main-thread display-callback gaps. To exercise a public website in
the content card instead:

```sh
VANE_UI_PERFORMANCE=1 VANE_LIVE_SITE_URL=https://obsidian.md/ swift test --filter LiveSidebarResponsivenessTests
```

Only three pages are loaded; the remaining rows are suspended tabs. These timings measure
native input and display-cycle availability, not compositor-presented frame rate or the
cost of loading hundreds of websites. Verify frame presentation separately in the affected
profile with its actual pages, using the target display refresh rate. A 60 Hz session
cannot establish 120 FPS.
Run timing diagnostics on an unlocked, otherwise idle desktop and keep the fixture
visible. The fixture skips detected occlusion; also discard a run if the desktop locks
or another workload interferes, even if AppKit still reports the window as visible.

The native sidebar keeps each row in a stable hosting owner and attaches owners around
the visible viewport. The normal resident range is 24 rows; canonical owner boundaries
can require up to 40 controls. Active editors, menus, reordered owners and larger
viewports can retain more. Scrolling does not walk detached cached control trees.
Accessibility queries preserve the real controls and editor instead of expanding the
entire outline. Set `VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE=0` or
`VANE_EXPERIMENT_THREE_RESIDENT_BATCHES=0` only for legacy comparisons.

For presentation timing, launch the exact Release test app with
`VANE_DIAG_SCROLL_TRACE=1`, confirm its real website tabs and selected content, then run:

```sh
python3 scripts/record-ui-frames.py --pid PID --executable /absolute/path/to/vane --output /absolute/new/capture --seconds 60
python3 scripts/analyze-ui-frames.py --run /absolute/new/capture --output /absolute/new/analysis --scroll-trace /absolute/path/to/vane-scroll-PID-UUID.json --expected-sidebar-rows 100
```

Start physical sidebar scrolling only after `RECORDING_STARTED`. The recorder saves the
full raw trace, including after an early stop. Analysis requires exact process identity,
input-clock alignment, foreground input, populated rows and movement. It reports every
joined target context separately, including p50, average, p95, p99, maximum and censored
tails. Compositor transactions alone do not prove changing pixels or a window's FPS.
The trace arms on the first physical sidebar scroll; relaunch the same signed app after
functional checks so those checks do not consume the measurement interval.

The offline recorder and analysis checks are:

```sh
python3 scripts/test-ui-frame-recording.py
python3 scripts/test-ui-frame-analysis.py
python3 scripts/test-ui-scroll-trace-analysis.py
```

Folder-opening diagnostics report toggle time, opening/closing layout, run-loop gaps, and
mounted native tab controls for 20/300-tab folders. They also guard against repeated
lock scans in an unprotected 3,000-tab strip and inactive-tab scans in the offscreen
media layer:

```sh
VANE_UI_PERFORMANCE=1 swift test --filter FolderOpeningPerformanceTests
```

Run comparisons on the same quiet logged-in Mac, with the same fixtures and build
configuration. Coordinate with other profiling/build tasks before collecting
timings; use `--skip-build` only after building the exact revision to measure.

## Release and graphical smoke checks

Before shipping, also check the release configuration:

```sh
swift build -c release
./.build/release/vane selfcheck --pure
./make-app.sh
./scripts/test-build-dmg.sh
```

### Signed browser smoke

On a logged-in macOS 26-or-later desktop, the smoke script creates a temporary signed
app and isolated test profile, then runs real WebKit assertions:

The smoke run also reports first-page setup and 100-tab session restoration timings. It
checks that parked rows need no web views, selecting a row creates its page, and global
settings and extension metadata queries keep background rows parked.

```sh
swift build
python3 scripts/check-browser-smoke.py
# Opt-in lifecycle measurement: 100 tab/window cycles, 25 suspend/resume cycles,
# 200 parked rows, 30s settling before/after, and 60s idle sampling.
python3 scripts/check-browser-smoke.py --lifecycle

# Opt-in Find retention and preview timer diagnostics. Build before reserving a
# quiet profiling window; the measurements then use the existing test executable.
swift build --build-tests
VANE_LIFECYCLE_MEASURE=1 swift test --skip-build --filter 'LifecycleEfficiencyTests|PreviewLoadingPerformanceTests'
```

### Public media and full selfcheck

For an opt-in network-dependent public streaming pass on a graphical test Mac:

```sh
python3 scripts/check-browser-smoke.py --public-media
```

This separately samples 90 seconds per clear/FairPlay Shaka demo asset, with
pause/seek/resume and player unload/reload. It uses no service accounts and does not
verify subscription playback, cross-network calls or system capture revocation. Exact
outcomes and limits belong in [the compatibility log](REAL-SITE-COMPATIBILITY.md).

The full `selfcheck` uses a keychain and a window server. Run it locally when those
services are available:

```sh
./Vane.app/Contents/MacOS/Vane selfcheck
```

For updater transport, transaction, native recovery, and unchanged notarized-candidate
checks, see [release validation](RELEASING.md#updater-and-distribution-validation).

## Project structure

| Path | Purpose |
| --- | --- |
| [`Sources/Vane/main.swift`](../Sources/Vane/main.swift) | CLI dispatch and application startup. |
| [`Sources/Vane/AppLifecycle.swift`](../Sources/Vane/AppLifecycle.swift) | Application delegate, Dock actions, and window lifecycle. |
| [`Sources/Vane/Engine.swift`](../Sources/Vane/Engine.swift) | Tabs, WebViews, navigation, and WebKit delegates. |
| [`Sources/Vane/SharedTabs.swift`](../Sources/Vane/SharedTabs.swift) | Shared Space tabs and live-page ownership between windows. |
| [`Sources/Vane/UI.swift`](../Sources/Vane/UI.swift) | Main browser window and SwiftUI controls. |
| [`Sources/Vane/Profiles.swift`](../Sources/Vane/Profiles.swift) | Profile and Space state, paths, and isolation. |
| [`Sources/Vane/Store.swift`](../Sources/Vane/Store.swift) | SQLite history and bookmarks. |
| [`Sources/Vane/LibraryWindow.swift`](../Sources/Vane/LibraryWindow.swift) | Downloads, media, archives, Spaces, and Easels browsing. |
| [`Sources/Vane/Easels.swift`](../Sources/Vane/Easels.swift), [`EaselWindow.swift`](../Sources/Vane/EaselWindow.swift) | Saved board data and the editing canvas. |
| [`Sources/Vane/PageCapture.swift`](../Sources/Vane/PageCapture.swift) | Element and region selection, page snapshots, and capture outputs. |
| [`Sources/Vane/BatterySaver.swift`](../Sources/Vane/BatterySaver.swift) | Battery-aware suspension and reduced preview/motion policy. |
| [`Sources/Vane/AppIcon.swift`](../Sources/Vane/AppIcon.swift), [`AppIcons/`](../AppIcons/) | Dock icon selection and bundled Icon Composer assets. |
| [`Sources/Vane/CloudAI.swift`](../Sources/Vane/CloudAI.swift), [`AIKeys.swift`](../Sources/Vane/AIKeys.swift) | Provider requests, privacy rules, and local API-key storage. |
| [`Sources/Vane/Passwords.swift`](../Sources/Vane/Passwords.swift) | Keychain integration, autofill, and the selfcheck runner. |
| [`Sources/Vane/Updater.swift`](../Sources/Vane/Updater.swift) | Release checks and authenticated XPC installation; the signed installer checks Gatekeeper and removes update quarantine before the locked, crash-recoverable swap. |
| [`Tests/VaneTests/`](../Tests/VaneTests/) | XCTest browser and UI regressions. |
| [`scripts/`](../scripts/) | Browser smoke, release-candidate, packaging, and integration checks. |

Additional persistence areas include `Backup*`, `ReadingQueue*`, `SpaceTemplate*`, and
`SiteBoost*` under `Sources/Vane`. The signed XPC entry points live under
`Sources/UpdateInstaller` and `Sources/IconService`; `installer/` contains their plists
and packaging support.

The public documentation website lives in `docs/*.html` with its existing CSS, scripts,
and `versions/` snapshots. Markdown topic guides are separate from that website. [App
screenshots](media/README.md), [audit evidence](README.md#reliability-and-validation),
and historical [plans](superpowers/plans/) / [specifications](superpowers/specs/) stay
in their existing locations.

### Website rendering checks

Run the galaxy scene regressions with Node. On a logged-in Mac, also run the real
WebKit probe: it verifies GPU shader linking and animation, then reports an eight-second
sample of callback and draw rates. Rates depend on the display and current system load;
they are diagnostics rather than a fixed performance budget. The probe uses a temporary
nonpersistent web view and closes its window when it exits.

```sh
node docs/tests/galaxy.test.cjs
swift scripts/check-site-rendering.swift
```

## Contributing and review

Start with the [contributor guide](../CONTRIBUTING.md) for a first change, issue
reporting, and PR expectations.

Follow [AGENTS.md](../AGENTS.md): work on an isolated `codex/` branch, preserve
unrelated changes, run relevant checks, open a PR, obtain an independent review of its
current head, address findings, and wait for required CI/approvals before
squash-merging. Merging does not publish a release.

When launching test apps, record each bundle path, PID, and process start time. Quit and
verify exit of every owned instance before finishing or abandoning work. Revalidate
identity before any targeted signal; leave the regular app and other tasks’ instances
running.

Report macOS, SDK, signing, fixture/account scope, and skips with validation. Historical
audits are evidence for their stated revision and environment, not proof that current
source passed the same checks.
