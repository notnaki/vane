<p align="center">
  <img src="AppIcons/Previews/Normal.png" width="96" height="96" alt="Vane app icon">
</p>

<h1 align="center">Vane</h1>

<p align="center">
  A native macOS browser. A little more room for the web.
</p>

<p align="center">
  Sidebar tabs · Spaces · Split View · Reader · Easels
</p>

<p align="center">
  <a href="https://github.com/notnaki/vane/releases/latest"><strong>Download Vane</strong></a>
  &nbsp;·&nbsp;
  <a href="https://vane.so/">Website</a>
  &nbsp;·&nbsp;
  <a href="docs/README.md">Documentation</a>
  &nbsp;·&nbsp;
  <a href="#contributing">Contribute</a>
</p>

<p align="center">
  macOS 26+ &nbsp;·&nbsp; Built with Swift &amp; WebKit &nbsp;·&nbsp; MIT licensed
</p>

<p align="center">
  <a href="https://github.com/notnaki/vane/actions/workflows/checks.yml"><img src="https://github.com/notnaki/vane/actions/workflows/checks.yml/badge.svg?branch=main" alt="CI checks"></a>
  <a href="https://github.com/notnaki/vane/releases/latest"><img src="https://img.shields.io/github/v/release/notnaki/vane" alt="Latest release"></a>
</p>

![Vane showing NASA Mars with sidebar tabs and Spaces](https://vane.so/media/vane-varied-spaces-v1-1536.webp)

<p align="center"><sub>Spaces, favourites, and the web in one native window. <a href="https://github.com/notnaki/vane/blob/website/media/README.md">About this screenshot</a>.</sub></p>

Vane is a browser built with Swift, SwiftUI, AppKit, and Apple's WebKit. It keeps
your tabs in a sidebar, sorts them into Spaces, and adds tools for reading,
collecting, and reshaping the web.

> **Vane is in active development.** These docs follow `main`, so a feature may
> land here a little before it reaches a release. Check the
> [limits](#limits) before making Vane your only browser.

## Install

1. Download `Vane.dmg` from the [latest release](https://github.com/notnaki/vane/releases/latest).
2. Open it and drag Vane to Applications.
3. Open Vane. You can skip the welcome, or use it to import from another browser.

Vane updates itself. Choose **Vane → Check for Updates…** to check now. To try early
builds, switch **Settings → General → Update channel** to **Nightly**; switching back
to **Stable** waits for the next stable release rather than downgrading.
[How releases work](docs/RELEASING.md#release-cadence).

## Features

| | |
| --- | --- |
| **Browsing** | Sidebar tabs, Favourites, pinned tabs, nested folders, Split View, Peek, Little Vane, private windows, and Translate. |
| **Organizing** | Spaces and Space templates, Tidy Tabs, Library, bookmarks, and searchable history. |
| **Reading** | Reader, an offline reading queue, find on page, and page capture. |
| **Media** | Picture in Picture, a sidebar mini-player, and Pause All Media. |
| **Making it yours** | Easels, per-site Boosts, themes, app icons, the Streamlined style, custom search engines, and rebindable shortcuts. |
| **Your data** | Profiles, Keychain passwords with Touch ID, passkeys, imports from Arc, Chrome and others, backups, and optional iCloud sync. |
| **Extensions** | Chrome Web Store and Safari extensions, content blocking with filter lists, GitHub Live Folders, and AI features with your own keys or ChatGPT plan. |

## Getting around

| Action | Shortcut |
| --- | --- |
| New tab or search | <kbd>⌘</kbd> <kbd>T</kbd> |
| Address bar | <kbd>⌘</kbd> <kbd>L</kbd> |
| Reopen closed tab | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>T</kbd> |
| Find on page | <kbd>⌘</kbd> <kbd>F</kbd> |
| Library | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>L</kbd> |
| History | <kbd>⌘</kbd> <kbd>Y</kbd> |
| Show Toolbar | <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>D</kbd> |

Swipe across the sidebar to change Spaces. Every shortcut can be changed in
**Settings → Shortcuts**. The [browsing guide](docs/BROWSING.md) covers the rest.

## Documentation

| Guide | Covers |
| --- | --- |
| [Everyday browsing](docs/BROWSING.md) | Tabs, Spaces, windows, search, shortcuts, Library, downloads, and media. |
| [Reading and customization](docs/FEATURES.md) | Reader, Easels, capture, Boosts, templates, appearance, and Battery Saver. |
| [Profiles, data, and privacy](docs/DATA-AND-PRIVACY.md) | Passwords, imports, backups, website data, iCloud, and private browsing. |
| [Extensions and integrations](docs/INTEGRATIONS.md) | Extensions, content blocking, site permissions, AI, and GitHub Live Folders. |
| [Development](docs/DEVELOPMENT.md) | Building, testing, and project structure. |

The [documentation index](docs/README.md) lists everything, including the
compatibility and reliability records. The [privacy policy](PRIVACY.md) explains
what Vane stores and sends. There is also a visual
[field guide](https://vane.so/docs.html) on the website.

## Build from source

You need macOS 26 or later and Xcode 26 or later.

```sh
git clone https://github.com/notnaki/vane.git
cd vane
./make-app.sh        # or ./make-app.sh debug for a faster build
open Vane.app
```

`make-app.sh` builds the app with its helpers, icons, and resources and signs it
for local use. Local builds don't include iCloud sync or passkeys, which need
Vane's provisioning profile. See [development](docs/DEVELOPMENT.md#setup-and-local-builds)
for tests and the CLI.

## Limits

Vane renders pages with the system WebKit, so site support follows your macOS version.

- **Not every site works.** Netflix (4K and Dolby Vision), Spotify, and Disney+
  play, but some sites and sign-ins still break. See the
  [compatibility record](docs/REAL-SITE-COMPATIBILITY.md).
- **Extensions are WebKit extensions.** Vane installs from the Chrome Web Store
  and fills in many Chrome-only APIs, but not every extension will work.
- **Folder uploads are off on macOS 27.0.x** because of a WebKit crash.
  Single files upload normally.
- **Password autofill is heuristic.** It can't reach closed shadow roots or
  cross-origin frames. iCloud Passwords aren't available to third-party browsers.
- **Unsaved form text can be lost** in a crash. See
  [draft protection](docs/DRAFT-PROTECTION.md) and [crash recovery](docs/CRASH-RECOVERY.md).
- **Some features use private WebKit APIs**, which a macOS update can break.

## Contributing

Bug reports, documentation fixes, and focused code changes are welcome. Start
with the [contributor guide](CONTRIBUTING.md).

To report a problem from inside Vane, choose **Help → Report a Problem…**. You
can attach recent diagnostic events (event names and error codes only, never URLs
or page content), preview the report, and open a prefilled GitHub issue. Nothing
is sent without you. You can also use the
[issue templates](https://github.com/notnaki/vane/issues/new/choose). Report
security issues [privately](https://github.com/notnaki/vane/security/advisories/new)
under the [security policy](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE). Bundled fonts are credited in
[Sources/Vane/EaselFonts](Sources/Vane/EaselFonts/SOURCE.md).
