# Development

[Documentation index](README.md) · [Project README](../README.md)

Use focused validation for the affected behavior. Documentation-only changes need link,
command-reference, and diff checks; they do not need the full local application suite.
Required PR CI still applies.

## Setup and local builds

Requires macOS 26 or later and Xcode 26 or later with its Swift toolchain. Xcode 27 is
needed to compile the macOS 27 location delegate; runtime availability is also checked.
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
through `selfcheck`. Routine CI builds the debug configuration, runs the pure checks and
XCTest regressions, checks icon selections and cloud AI behavior, tests CLI import
errors and workflow fixtures, assembles the debug app, and exercises the DMG packager
and update installer. Debug builds avoid whole-module release optimization on every
change. CI caches `.build` by macOS architecture, Swift/Xcode/SDK versions, and
package/source hashes, and cancels superseded runs for the same branch or PR. SwiftPM
still validates the build on every cache hit. A timestamp snapshot in the cache restores
the previous modification time only when an input's SHA-256 still matches, letting
unchanged files stay incremental across fresh checkouts. Pull requests only restore
caches; successful `main` checks save them and retain the two newest Swift debug caches.
The release workflow builds and smoke-tests the optimized app; its build products are
never cached because they can contain the OAuth secret.

### Routine CI commands

To run the same checks configuration locally:

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
scripts/check-webkit-startup.sh
swift test
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
swift test --filter 'PasswordAutofillTests|PasswordOriginTests|PasswordChooserLayoutTests|PasswordPopupPresentationTests|PasswordManagerSearchTests|PasswordGeneratorTests'
python3 scripts/check-browser-smoke.py
```

The autofill fixtures exercise real WebKit documents, controlled input events, dynamic
visibility, account continuity, embedded forms, stale chooser targets, and scoped
Keychain reads. Keychain-dependent XCTest fixtures report a skip if storage is
unavailable.

### Specialist reliability fixtures

For site-permission lifecycle fixtures and a fake display-capture check, see
[Site permissions on macOS 27](SITE-PERMISSIONS.md#validation-and-remaining-platform-coverage).

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
# Opt-in lifecycle measurement: 100 tab/window cycles, 200 parked session rows,
# at least 30s settling and 60s idle sampling (logged-in desktop required).
python3 scripts/check-browser-smoke.py --lifecycle
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
