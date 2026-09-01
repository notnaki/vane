# Vane

A native macOS browser, written in Swift and SwiftUI on top of WebKit.

Vane is a single executable target that links `AppKit`, `WebKit` and the system
`libsqlite3` and nothing else. There is no Electron, no CEF, no vendored Chromium and no
bundled rendering engine — the pages are rendered by the same `WKWebView` and the same
Apple-signed WebKit content and network processes that Safari uses. The release binary is
around 2.3 MB and `Vane.app` is that binary plus a generated `Info.plist`.

Requires macOS 26 or later. `Package.swift` declares `.macOS("26.0")` and the bundle sets
`LSMinimumSystemVersion 26.0`, because the WebKit APIs the app is built on (`WKWebExtension`,
`isInspectable`, `pageZoom`) do not exist on older systems.

This is a work in progress. It browses, but it is not finished — see
[Limitations](#limitations) before you rely on it.

## Why WebKit and not Chromium

The usual reason to embed Chromium is that you want Chrome's web platform. The reason not
to, on a Mac, is DRM.

Netflix, Disney+, Prime Video, HBO Max and every other premium streaming service serve
encrypted media through EME, and EME only decrypts if the browser can hand the stream to a
Content Decryption Module the service will accept. On macOS there are two realistic
candidates. FairPlay Streaming (`com.apple.fps`) is Apple's own CDM: it is part of the
operating system, WebKit exposes it to any host that embeds `WKWebView`, and there is no
per-application licence to obtain, no key to be issued and no contract to sign in order to
get a decrypt path. Widevine (`com.widevine.alpha`) is Google's, and it is not part of
macOS — it ships inside Chrome and inside Electron-adjacent hosts that have gone and got
it. Getting Widevine into a browser that is not Chrome means obtaining the CDM binary from
Google under licence and, for anything above the software-only security level, having your
host application VMP-signed (Verified Media Path) by Google so the CDM will trust the
process it has been loaded into. That signing is granted per vendor, on Google's schedule
and at Google's discretion. It is the entire reason castLabs maintains a separately signed
fork of Electron: an unmodified Electron build cannot play protected content, and getting
it to is a business relationship, not a build flag. Without VMP the fallback is Widevine's
software security level, which the major services deliberately treat as the untrusted tier
and cap at SD or 720p — so even the version you can get working streams worse than Safari
does on the same machine.

Building on WebKit skips all of that. FairPlay is already there, and the tiers the
services gate behind hardware-backed DRM are the ones Safari already gets on the same Mac.

There is a runnable check for the claim rather than an assertion of it:

```
$ vane drmcheck
engine:     WKWebView (WebKit) — macOS system engine
user agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15

FairPlay (modern)                 YES (com.apple.fps, CDM loads)
FairPlay (legacy)                 YES (com.apple.fps.1_0, CDM loads)
Widevine                          no  (NotSupportedError)
PlayReady                         no  (NotSupportedError)
Clear Key (no premium content)    YES (org.w3.clearkey, CDM loads)

=> FairPlay available: premium streaming has a decrypt path.
```

Two details in `Sources/Vane/DRMCheck.swift` make that output mean something. The probe
runs inside a real `https` origin — a simulated response for `https://vane.test/drmcheck`,
not `about:blank` — because EME refuses to answer in a non-secure context and would give a
false negative. And it does not stop at `navigator.requestMediaKeySystemAccess()`, which
only tells you the engine recognises the key-system name; it goes on to call
`access.createMediaKeys()`, so a `YES` line means the CDM actually instantiated. The exit
code is 0 only if a FairPlay line came back `YES`.

`vane drmcheck <url>` is the end-to-end version: it opens a real window, loads the page,
and polls the largest `<video>` every three seconds for up to 45 seconds, reporting
`currentTime`, `readyState` and whether media keys were attached. It exits 0 once the video
passes one second of playback, which is proof that a licence was fetched and frames are
decrypting — not just that the CDM exists.

The catch, stated plainly: Vane sends Safari's user-agent string by default
(`Sources/Vane/Engine.swift`). WKWebView's own UA gets bounced by the streaming services on
sight, and FairPlay is in practice only offered to clients that present as Safari. That is
a deliberate compatibility lie, and it is the sort of thing a service can change its mind
about at any time.

## Build and run

```
./make-app.sh && open Vane.app
```

`make-app.sh` runs `swift build -c release`, then assembles `Vane.app` by copying the
binary in and generating an `Info.plist` beside it. It takes an optional configuration
argument (`./make-app.sh debug`). `VANE_VERSION` and `VANE_BUILD` override the version
strings, which otherwise come from `git describe` and the commit count.

Signing is controlled by one environment variable:

```
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
```

With `SIGN_ID` set the bundle is signed with the hardened runtime, a secure timestamp and
`Vane.entitlements`. With it unset the bundle is ad-hoc signed instead — enough to run on
the machine that built it, not enough for anyone else.

`Vane.entitlements` is short on purpose. WebKit runs JavaScript and the CDM inside
Apple-signed XPC services, so the app itself needs only `allow-jit`, `network.client`, and
the camera and microphone device entitlements — a hardened-runtime app is denied capture
by the OS before a site's own permission prompt is ever reached. The app is not sandboxed.

### CLI

The executable is `vane`, and everything below is what `Sources/Vane/main.swift` actually
dispatches on:

| Command | What it does |
| --- | --- |
| `vane` | Launch the browser. Restores the last session unless that is turned off. |
| `vane <url>` | Launch and open that URL, beating a restored session. Matched on the `http` prefix. |
| `vane drmcheck` | Probe the available EME key systems and exit. See above. |
| `vane drmcheck <url>` | Load a real page and report whether a protected `<video>` actually advances. |
| `vane selfcheck` | Run every assertion, including the ones that need the keychain and a window server. |
| `vane selfcheck --pure` | Run only the assertions that need neither. This is what CI runs. |
| `vane import <file>` | Import passwords from a browser's CSV export, print the counts, exit. |

`vane import` writes straight into the login keychain and then tells you to delete the
file, because a password CSV export is plain text. The same importer is reachable from the
Passwords menu with a file panel.

## Testing

There is no XCTest target. The checks live next to the code they cover, as `check()`
functions returning `[(String, Bool)]`, and `SelfCheck` in `Sources/Vane/Passwords.swift`
runs them all.

```
$ swift run -c release vane selfcheck
...
PASS
```

As of this commit that is **313 assertions**, in these groups: store, content blocker,
browser import, favicons + tabs, url handling, error pages, site permissions, extensions,
profiles + spaces, search engines, certificate trust, crash recovery, reader, command
palette, csv import, keychain round-trip, autofill script.

```
$ swift run -c release vane selfcheck --pure
...
PASS (pure)
```

`--pure` is the same run stopped before the last two groups — **304 assertions**. It is
checked before AppKit is touched at all, so it needs no window server, and it never reaches
the keychain, so it needs no keychain ACL and cannot prompt. That subset is what
`.github/workflows/checks.yml` runs on a `macos-26` runner, alongside `swift build -c
release` and `./make-app.sh`. The remaining nine assertions — the keychain round-trip and
the autofill script driven against a real form in a real `https` origin — stay a local
`vane selfcheck`, where a real signed bundle is what makes them meaningful.

Several modules take an injected `UserDefaults` or directory so their assertions never
touch your real preferences, keychain items or Application Support folder.

## Features

Everything here is implemented and reachable from the UI.

**Browsing**

- Tabs with favicons, drag-to-reorder, and pinning. Pinned tabs sit ahead of the rest,
  survive a relaunch, and are stored per profile.
- Multiple windows; private windows, which get a non-persistent website data store and are
  never written to disk.
- Address bar that decides between navigation and search: bare hosts, `localhost:3000`,
  IPs, file paths and `~/` paths all navigate. A leading `!bang` picks one of the configured
  engines by id prefix (`!g swift` → Google, `!g` alone → its front page); an unrecognised
  bang is handed to the current engine intact, which is the right answer on DuckDuckGo and
  harmless anywhere else. Suggestions come from history and bookmarks, keyboard-navigable.
- Six built-in search engines (DuckDuckGo, Google, Bing, Brave, Kagi, Ecosia) plus custom
  engines defined with a `%s` template.
- Find on page (`⌘F`) using WebKit's own find, with wrap.
- Reader mode (`⌥⌘R`): the DOM walk runs in JavaScript and returns a node tree as JSON, and
  everything after that — escaping, URL resolution, the tag whitelist, the 140-word "is
  there enough article here" threshold — is Swift, so it is asserted offline. Adjustable
  font size and a serif/sans toggle.
- Downloads to `~/Downloads` without overwriting, with progress and Show in Finder.
- Session restore, plus crash recovery: a marker file that exists while Vane runs and a
  30-second autosave, so a WebKit content-process take-down does not cost you the session.
  Reopen closed tab (`⌘⇧T`) keeps a 32-deep URL stack.
- Command palette (`⌘⇧P`) over tabs, history, bookmarks and commands, and the same overlay
  restricted to open tabs (`⌘⇧A`), with a subsequence matcher scored for prefix, word-start
  and contiguity.
- Explicit VoiceOver work throughout the chrome: labels, values, custom actions, sort
  priorities, spoken announcements for things that only change colour, and Reduce Motion
  handling on the loading bar.

**Data**

- History and bookmarks in one SQLite file per profile, with a bulk-insert path that puts
  20,000 visits in one transaction.
- Profiles: separate data store, database, keychain items, favicons, pins, session,
  extensions and spaces. Spaces are named tab groups inside a profile.
- Passwords saved as ordinary Internet keychain items, stamped with a creator code so Vane
  can only ever read credentials Vane created. Autofill only over `https`, never
  auto-submitting, and the injected script goes through the native value setter so
  React-style controlled inputs actually update.
- Import passwords from a CSV export (Chrome, Edge, Brave, Opera, Vivaldi, Arc, Firefox,
  Safari, macOS Passwords, 1Password, Bitwarden), with an RFC 4180 parser.
- Import history and bookmarks directly from Chrome, Chromium, Edge, Brave, Vivaldi, Opera,
  Arc, Firefox and Safari, read-only and without touching any encrypted store.

**Privacy and security**

- Ad and tracker blocking through `WKContentRuleListStore` — WebKit's declarative blocker.
  Rules compile to bytecode and are evaluated in the network process, so nothing is
  injected into the page and a blocked request never leaves the machine. Ships a small
  built-in list and converts a documented subset of EasyList syntax, so uBlock/AdGuard
  subscription files can be added from disk. On by default, per profile.
- Per-site camera and microphone prompts, remembered per host, with a reset command.
- Certificate errors surface a two-step alert with the leaf's SHA-256 fingerprint;
  exceptions are keyed on host *and* certificate, so a swapped certificate asks again.
  HTTP Basic auth lives in the same delegate and stores its credential `.forSession` only.
- Error pages written in plain language for the common `NSURLError` cases, loaded as a
  simulated response so the failed URL stays in the address bar and Try Again retries the
  right thing.

**Developer**

- `WKWebExtension` support: install an unpacked MV2/MV3 extension by pointing a file panel
  at the folder containing `manifest.json`. One controller per profile, with adapters that
  expose Vane's tabs and windows to the extension APIs.
- Web Inspector (`⌥⌘I`), JavaScript console (`⌥⌘C`), View Source (`⌥⌘U`), a user-agent
  picker, and a toggle for `isInspectable`.
- Registers as a browser via `CFBundleURLTypes`, handles the GetURL Apple Event so links
  from Mail, Slack and `open -a Vane <url>` land in a tab, and offers once to become the
  default browser.

## Limitations

Honest list. Most of these are deliberate shortcuts marked in the source with a
`// ponytail:` comment naming the ceiling and the upgrade path — `grep -rn "ponytail:"
Sources/` is the full ledger.

**Distribution**

- The app is ad-hoc signed unless you supply `SIGN_ID`. An ad-hoc bundle will not pass
  Gatekeeper on any machine other than the one that built it. There are no notarized
  releases.
- There is no auto-updater. No update check, no server, nothing.

**UI**

- The interface is provisional and is being redesigned. The settings window is explicitly a
  plain `TabView` of grouped `Form`s borrowing System Settings' shape with no design work
  done on it.
- There is no history window, no bookmarks manager, no downloads window and no saved-password
  UI — history and bookmarks are menus capped at 25 and 40 entries, downloads are a popover,
  and password management hands you off to Keychain Access.
- Several prompts are app-modal `NSAlert`s rather than sheets: certificate errors, HTTP
  auth, camera/microphone. A background tab hitting a bad certificate steals focus.

**Content blocking**

- The EasyList converter handles a documented subset only. `$important`, `$redirect`,
  `$csp`, `$removeparam`, `/regex/` rules, negated resource types, procedural selectors and
  scriptlets are counted and dropped rather than half-translated. A mixed
  `$domain=a.com|~b.a.com` keeps the positives and drops the exclusions, because WebKit
  rejects a trigger carrying both.
- The built-in list is a static constant with no updater and no subscription schedule. New
  rules mean adding a filter list by hand.
- Added filter lists are remembered by path. Move or delete the file and it silently stops
  applying.

**Data and sync**

- Nothing syncs. Keychain items are local-only (no `kSecAttrSynchronizable`), and there is
  no iCloud or account layer of any kind.
- Only one credential per host is offered — with several accounts saved, the first one
  wins. There is no picker.
- The password autofill heuristic is best-effort: it takes the last text-ish input before
  the password field, only in the main frame, and a site that logs in with no navigation at
  all never triggers a save offer.
- Browser import takes the newest N URLs, not the whole table. Cookies and sessions do not
  come across.
- Switching spaces tears the tabs down and reloads them from URLs, so scroll position and
  the back/forward list are lost. Session restore and reopen-closed-tab have the same
  ceiling.
- Pins are one shared set per profile; pinning in two windows at once is last-writer-wins.

**Platform**

- The in-app inspector is opened through WebKit SPI (`_inspector` / `_WKInspector`). Every
  hop is `respondsToSelector`-guarded, so if Apple drops it the menu item goes inert and
  right-click → Inspect Element still works — but it is SPI.
- Extensions are granted everything their manifest requests at install time, with no
  permissions sheet listing what is about to be granted. Runtime prompts for anything
  requested *later* are wired up.
- Crash detection cannot tell a crash from a force-quit or a logout, so either produces a
  "reopen tabs?" prompt.
- The SQLite connection is one connection used from the main thread, and favicon reads are
  synchronous file IO on the main thread.
- Only the leaf certificate is inspected in the trust dialog, not the chain.
- No translation. Every string is inlined English; the error pages are one interpolated
  HTML string with no template file.

## Architecture

One executable target, `Sources/Vane`, no internal modules — 26 files, about 7,300 lines
including the comments, which carry most of the reasoning.

| File | Owns |
| --- | --- |
| `main.swift` | Top-level bootstrap: argument dispatch, crash marker, first window, menu, run loop. No `AppDelegate`, no `@main`. |
| `Engine.swift` | `Tab` and `TabStore` — the `WKWebView` per tab, the KVO that republishes its state, the delegates, and the tab strip's model including pins and spaces. Also the Safari UA string. |
| `Window.swift` | `Windows` (live window bookkeeping), `Session` (per-profile restore file), `ClosedTabs` (the reopen stack). |
| `UI.swift` | The whole SwiftUI chrome: tab strip, toolbar, address field, suggestions, find bar, save-password prompt, downloads popover, loading bar, and the accessibility layer. |
| `Menu.swift` | The AppKit main menu, rebuilt rather than mutated because its items carry live state. |
| `Palette.swift` | The command palette: the subsequence matcher (pure, and asserted offline), the command list, and the overlay view. |
| `SettingsWindow.swift` | `Prefs` (homepage, session restore) and the settings window's three panes. |
| `Store.swift` | History and bookmarks in SQLite — one connection per profile, plus the ranking behind address-bar suggestions. |
| `Profiles.swift` | `Profile`, `Space`, and `ProfileManager`: the profile list, the active selection, and every per-profile path and defaults key. |
| `Passwords.swift` | Keychain storage, the autofill script and its message bridge, and `SelfCheck` — the `vane selfcheck` driver. |
| `Import.swift` | An RFC 4180 CSV reader and the password-export importer built on it. |
| `BrowserImport.swift` | Reading history and bookmarks out of other browsers' unencrypted files: Chromium SQLite/JSON, Firefox `places.sqlite`, Safari's plist. |
| `Blocker.swift` | EasyList → `WKContentRuleList` JSON conversion, the compile cache keyed on a hash of that JSON, and the built-in starter list. |
| `Reader.swift` | Reader mode: the in-page extraction contract, the Swift-side sanitiser and document builder, and the per-tab on/off state. |
| `SearchEngines.swift` | `SearchEngine`, the built-in list, custom engines, and the decision procedure that turns address-bar input into a URL or a search. |
| `Favicons.swift` | Per-profile favicon fetch, memory + disk cache, sweep by modification date at 300 files. No third-party proxy. |
| `Downloads.swift` | `WKDownloadDelegate`: destination policy, de-duplicated filenames, and the list the popover shows. |
| `Permissions.swift` | Per-site camera and microphone decisions, remembered in `UserDefaults`. |
| `CertificateTrust.swift` | The bad-certificate flow, the fingerprint-keyed exception store, and HTTP Basic auth. |
| `ErrorPage.swift` | Turning an `NSError` into plain language and an HTML page, and deciding which failures are worth showing at all. |
| `Extensions.swift` | `WKWebExtension` hosting: one controller per profile, manifest validation, install/remove, and the tab and window adapters WebKit asks for. |
| `URLHandling.swift` | Being the system's browser: the GetURL Apple Event handler and the default-browser prompt. |
| `Crash.swift` | The running-marker file and the periodic session autosave that make crash recovery possible. |
| `Develop.swift` | `Inspector` (the SPI hop that opens the Web Inspector) and `Settings` (user agent, inspector toggle). |
| `DRMCheck.swift` | `vane drmcheck` — the EME key-system probe and the real-page playback test. |

## License

MIT. See [LICENSE](LICENSE).
