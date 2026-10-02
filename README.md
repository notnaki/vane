# Vane

A native macOS browser built with Swift, SwiftUI, AppKit, and WebKit. Pages run in
Apple's `WKWebView`; Vane supplies the tabs, sidebar, profiles, settings, and other
browser controls around it.

> **Status:** Vane is in active development and requires **macOS 26 or later**. It
> is useful for testing, but its release and real-site compatibility checks are
> still in progress. See [known gaps](#known-gaps) before relying on it as your
> only browser.

## Get started

Build a local app with Xcode 26 and the Swift toolchain it includes:

```sh
./make-app.sh
open Vane.app
```

`make-app.sh` builds the release executable, assembles `Vane.app`, adds the icon,
and signs the bundle ad hoc. You can also build just the command-line executable:

```sh
swift build -c release
./.build/release/vane selfcheck --pure
```

An ad hoc signed local build is for development on your Mac. Distribution requires
a Developer ID signature and notarization; see [releasing](#releasing).

## What Vane can do

| Area | Available now |
| --- | --- |
| Browsing | Tabs, pinned tabs, multiple windows, private windows, session restore, find on page, reader mode, picture in picture, and Web Inspector. |
| Organization | Spaces, sidebar folders, bookmarks, a searchable history window, Library, and a command palette. |
| Data | Separate profiles, downloads, saved passwords, and import of bookmarks, history, and password CSV exports. |
| Controls | Custom search engines and `!bang` shortcuts, per-site controls, keyboard shortcut settings, and appearance settings. |
| Protection | WebKit content blocking, HTTPS-only mode, certificate warnings, and site permission prompts. |
| Extras | Unpacked WebExtensions, GitHub-backed live folders, and an in-app update check for published releases. |

Windows in the same Space share tabs. When both show the same tab, the focused
window holds its live page and the other shows a gray snapshot. Switching windows
preserves input, scroll position, and history; closing a tab removes it from every
window. Each window keeps its own selection. Private and Little Vane windows keep
their own pages.

Some features depend on macOS services, site behavior, or a signed distribution
build. The [known gaps](#known-gaps) section gives the practical limits.

### A few shortcuts

| Action | Default shortcut |
| --- | --- |
| New tab | `⌘T` |
| Reopen closed tab | `⇧⌘T` |
| Find on page | `⌘F` |
| Search tabs | `⇧⌘A` |
| Search commands | `⇧⌘P` |
| Open Library | `⇧⌘L` |

Shortcuts can be changed in Settings. The menu bar shows the current bindings.

## Command line

The executable is `.build/release/vane` after `swift build -c release`. These
examples use `vane` as shorthand for that path.

| Command | Result |
| --- | --- |
| `vane` | Open the browser, restoring the last session when enabled. |
| `vane https://example.com` | Open a URL in the browser. |
| `vane selfcheck --pure` | Run checks that need neither a keychain nor a window server. |
| `vane selfcheck` | Run the full local checks, including keychain and WebKit checks. |
| `vane browsercheck` | Run real WebKit checks inside a signed, isolated app bundle; use the smoke-test script below. |
| `vane import passwords.csv` | Import a browser password CSV into the login keychain. |
| `vane drmcheck` | Probe which encrypted-media key systems WebKit can initialize. |
| `vane drmcheck <url>` | Check whether a protected video advances on a page. |

Password exports contain plain text credentials. Delete a CSV export when you no
longer need it. The same importer is available from Vane's Passwords UI.

### WebKit and protected media

Vane uses the system WebKit engine rather than bundling Chromium. `drmcheck`
tests the encrypted-media path available to the current macOS WebKit build. A
successful key-system probe does **not** guarantee that a particular streaming
service will play: the service, account, license exchange, and playback still
need a real-site test. `drmcheck <url>` checks playback progress on a page you
provide.

## Test a change

The project has one Swift executable target and no XCTest target. Its checks are
run through `selfcheck`; routine CI builds the debug configuration, runs the pure
checks, assembles the debug app, and tests the DMG packager. Debug builds avoid
whole-module release optimization on every change. CI caches `.build` by macOS
architecture, Swift/Xcode/SDK versions, and package/source hashes, and cancels
superseded runs for the same branch or PR. SwiftPM still validates the build on
every cache hit. A timestamp snapshot in the cache restores the previous modification
time only when an input's SHA-256 still matches, letting unchanged files stay
incremental across fresh checkouts. The release workflow builds and smoke-tests the optimized app;
its build products are never cached because they can contain the OAuth secret.

To run the same checks configuration locally:

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
./make-app.sh debug
./scripts/test-build-dmg.sh
```

Before shipping, also check the release configuration:

```sh
swift build -c release
./.build/release/vane selfcheck --pure
./make-app.sh
./scripts/test-build-dmg.sh
```

For a logged-in macOS 26 desktop, the smoke script creates a temporary signed
app and isolated test profile, then runs real WebKit assertions:

```sh
swift build
python3 scripts/check-browser-smoke.py
```

The full `selfcheck` uses a keychain and a window server. Run it locally when
those services are available:

```sh
./Vane.app/Contents/MacOS/Vane selfcheck
```

To verify an *unchanged, notarized* release ZIP on a graphical test machine:

```sh
scripts/check-release-candidate.sh Vane.zip /path/to/empty-evidence-directory
```

That script checks the archive and bundle contents, signature, stapled ticket,
Gatekeeper assessment, and WebKit smoke test, and saves evidence. A clean Mac
installation and upgrade still need to be exercised separately.

## Releasing

Merging a PR to `main` does not publish a release. Start the release workflow
for a patch bump (or choose `minor` or `major`):

```sh
gh workflow run release.yml
gh workflow run release.yml -f bump=minor
```

Alternatively, push a specific `v*` tag:

```sh
git tag v1.2.3
git push origin v1.2.3
```

The workflow builds `Vane.app`, packages `Vane.dmg` and `Vane.zip`, and publishes
them to a GitHub Release. To produce a Developer ID signed and notarized build,
the repository needs `DEVELOPER_ID_CERT_P12_BASE64`,
`DEVELOPER_ID_CERT_PASSWORD`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, and
`AC_API_KEY_P8_BASE64` as Actions secrets. The workflow stops before publishing
if any of these five credentials is missing. A tag containing a hyphen, such as
`v1.2.3-rc1`, publishes a prerelease that the in-app updater does not offer.

Local Developer ID builds can use:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
```

This signs the bundle but does not notarize it. Check the exact release archive
with `check-release-candidate.sh` before treating it as a distribution build.

## Known gaps

- Real-site coverage is still needed for sign-in providers, passkeys, uploads,
  printing, protected media, device permissions, and complex web apps.
- Password autofill is heuristic. Sites with unusual forms or login flows may
  need manual entry; multiple saved accounts for one host are not fully handled.
- Content blocking supports a documented subset of EasyList syntax. Filter
  lists added from disk do not update on a schedule.
- Data does not sync between Macs. Imports do not bring over browser cookies or
  signed-in sessions.
- Some system dialogs are app-modal, and some browser features depend on WebKit
  behavior that can change with macOS releases.
- Distribution readiness requires a real signed and notarized candidate,
  clean-Mac install and upgrade checks, and broader compatibility testing.

The tracked engineering work is in
[browser readiness](docs/BROWSER-READINESS-TODO.md).

## Project map

| Path | Purpose |
| --- | --- |
| [`Sources/Vane/main.swift`](Sources/Vane/main.swift) | CLI dispatch and application startup. |
| [`Sources/Vane/Engine.swift`](Sources/Vane/Engine.swift) | Tabs, WebViews, navigation, and WebKit delegates. |
| [`Sources/Vane/UI.swift`](Sources/Vane/UI.swift) | Main browser window and SwiftUI controls. |
| [`Sources/Vane/Profiles.swift`](Sources/Vane/Profiles.swift) | Profile and Space state, paths, and isolation. |
| [`Sources/Vane/Store.swift`](Sources/Vane/Store.swift) | SQLite history and bookmarks. |
| [`Sources/Vane/Passwords.swift`](Sources/Vane/Passwords.swift) | Keychain integration, autofill, and the selfcheck runner. |
| [`Sources/Vane/Updater.swift`](Sources/Vane/Updater.swift) | Release checks and authenticated XPC installation; the signed installer checks Gatekeeper and removes update quarantine before the locked, crash-recoverable swap. |
| [`scripts/`](scripts/) | Browser smoke, release-candidate, and packaging checks. |

## License

MIT. See [LICENSE](LICENSE).
