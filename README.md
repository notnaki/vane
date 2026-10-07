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

Fresh installations open with a short, skippable welcome to search and Spaces.
Finishing or skipping it leads into browsing; existing installations skip it.
Reduce Motion and Battery Saver keep the welcome still.

Local, debug, and prerelease builds skip the startup default-browser prompt. Stable
release builds packaged with `SIGN_ID` offer it once. You can still use the manual
“Make Vane Default…” action in Settings.

## What Vane can do

Picture in Picture uses a custom floating window that you can drag anywhere and
resize, with Back to Tab, minimize, close, play/pause, 15-second skips, and a seek
bar. Hold the seek knob and drag upward for finer horizontal seeking; the center
shows the current precision (2×, 4×, 8× and up) while you scrub. The corners have
larger resize targets that preserve the video's proportions and opposite corner. It remembers
its last position and size when reopened. Entry moves the live video from its
on-page position to the saved placement in one short motion. Back to Tab reveals
the source tab and moves the live video back to its current on-page position.
Reduce Motion keeps these transitions in place. Minimize
hides it while playback continues. The sidebar video player appears after minimizing PiP.
It stays available across this window's Spaces, including Spaces in other profiles.
Returning to its source Space keeps the minimized player visible until you open its tab,
restore Picture in Picture, or close the player.
It keeps the site icon and transport controls visible; hover over it to see the title, restore Picture in Picture,
or close the player and pause. Embedded players use their own frame and
Media Session play/pause and skip handlers.
The custom window keeps WebKit's original live video presentation, including
embedded players; when its presentation view cannot be safely attached, Vane
keeps the native Picture in Picture window as a fallback.

| Area | Available now |
| --- | --- |
| Browsing | Tabs, pinned tabs, multiple windows, private windows, Split View, Peek, Little Vane, session restore, find on page, reader mode, picture in picture, page capture, and Web Inspector. |
| Organization | Spaces, sidebar folders, bookmarks, a searchable history window, Library, and a command palette. |
| Data | Separate profiles, downloads, a bookmark manager, a saved-password manager and account chooser, and import of bookmarks, history, and password CSV exports. |
| Controls | Battery Saver, custom search engines and `!bang` shortcuts, per-site controls, keyboard shortcut settings, themes, and a Dock icon picker. |
| Protection | WebKit content blocking, HTTPS-only mode, certificate warnings, and site permission prompts. |
| Easels | Saved visual boards with notes, images, web captures, drawing, zoom, undo/redo, and export. |
| Extras | Unpacked WebExtensions, GitHub-backed live folders, and an in-app update check for published releases. |

Type a site word such as `youtube`, `github`, or `twitter` in the search bar and
press **Tab** (or click **Search …**) to turn it into a site search chip. Shortcut
keywords such as `yt` and your custom bangs work too. Typing `!yt ` activates the
chip directly. The selected result uses the site's chip color; **Return** searches
that site, and an empty query opens its home page. **Escape**, clicking the chip,
or **Backspace** with an empty query leaves site search. Words remain ordinary
searches until activated. Tab still searches actions when no site shortcut matches.
Built-in sites also include Twitch, TikTok, Pinterest, Bluesky, IMDb, SoundCloud,
Vimeo, Letterboxd, Goodreads, Medium, Etsy, Target, Dribbble, Behance, Unsplash,
Pexels, GitLab, and DEV.to. Full site names work with `!` too, such as `!youtube`
and `!github`; `twitter` and `!twitter` search X. Some sites require sign-in.

Windows in the same Space share tabs. When both show the same tab, the focused
window holds its live page and the other shows a gray snapshot. Switching windows
preserves input, scroll position, and history; closing a tab removes it from every
window. Each window keeps its own selection. Private and Little Vane windows keep
their own pages. Split View shows two to four pages side by side or stacked, with
resizable dividers. Peek opens a link over the current page; Little Vane opens it
in a separate compact window.

Drag a sidebar tab to reorder it: the white line marks the nearest insertion gap,
and the rows stay in place until you release. The line fades in once and stays visible
while moving between gaps. The held ghost matches the tab row.
Hold Option while dropping onto the middle of another tab to make a split view.
Dropping into a closed folder highlights it and opens its icon while you hover.

After Tidy groups Today tabs into folders, drag a tab or selection into the blank
space below the last row to move it outside the folders at the bottom of Today.
That drop area remains available when the last row is a collapsed folder or the
list fills the sidebar. Dropping onto **New Tab** moves tabs to the top of Today;
right-click → **Remove from Folder** keeps tabs in their section. An empty Today
folder disappears. Click and drag the blank area below Today tabs to move the window.

Drag a tab onto a favourite tile or into the gaps between tiles to add it to Favourites.
Approaching Favourites reveals a drop tile when it is empty; the address pill also accepts
the first favourite. Nearby tiles move aside and the drag preview takes its destination
tile's shape, then transforms back into a row when dragged out. This previews placement;
the order commits only on release. Drag tiles to reorder them or move
them into Pinned or Today. Links dragged from a webpage or another app can be dropped
onto the grid or address pill to save a favourite; dragging a tile into another app
exports its page link.

Right-click a sidebar folder and choose **Lock Folder** to hide all of its tabs and
nested folders. Click the locked folder to show its unlock controls in the page card. Touch ID
starts automatically when the locked page appears; touch the sensor to unlock without
clicking another button. Authentication stays inline; **More unlock options…** opens macOS
authentication,
where you can choose your Mac login password. Without available Touch ID,
**Unlock folder…** is the main action and uses macOS authentication.
Settings → Profiles → Passwords → **Folder unlock method** can select **System**
to open macOS authentication directly whenever you request an unlock.
If a page inside is open when you lock,
Vane replaces it with a heavily blurred, frozen backdrop and an unlock message;
the page stops running and cannot receive input. Unlocks last until you relock,
quit Vane, or the Mac locks, sleeps, or switches users. **Remove Lock…** requires
fresh authentication. Locks protect access inside Vane; they do not encrypt saved
tabs, history, or browser data, and history remains available in the Library.

Hover a sidebar tab to see a compact name tooltip and a **Double-click to rename** hint.
Double-click a Today tab, pinned tab, favourite, or split pane to edit its name in
place. Press **Return** to save or **Escape** to cancel; an empty name restores the
page’s title.

Hover the Library bucket in the sidebar footer to preview the last four downloads,
with the newest at the bottom. Thumbnails, filenames, and relative times appear over
the lower Today tabs; click a finished file to open it or right-click to show it in
Finder. **Settings → General → Previews → Library hover preview** selects Downloads
(the default), Media, Easels, Spaces, Archived Tabs, History, or Off. Each preview
shows up to four items. Downloads and Media are shared across all regular profiles
and windows; the other previews use this window's profile. Private windows show only
their own downloads, media, and archived tabs. The bucket is empty when downloads,
archived tabs, and the selected preview are empty, and always highlights on hover.
A filled bucket lifts its contents without changing their shape; an empty one lifts its lid.
Reduce Motion and Battery Saver keep these changes immediate. Click the bucket to
open the full Library.

Pinned tabs keep their saved name as you navigate within them. When a pinned tab
leaves its saved page, its sidebar row shows `/` before its title and offers
**Return to Pinned Tab**; returning
loads the pinned URL again. Favorites belong to a profile, while pinned and Today
tabs belong to a Space. Library lists Spaces across all profiles.
Swipe right to left within the Library panel to close it, or use Escape or its
back button. From the leftmost Space, swipe left to right over the sidebar to
open Library at its last-used section. Swipes over page content stay with the page,
including back and forward navigation. Vertical scrolling still scrolls the Library.

Hover the Space card to reveal its chevron and `…` menu. Click the card to collapse
or expand its pinned tabs; Today stays visible. Double-click its name to rename
the Space. Each window remembers the collapsed state for each Space while open.
Swipe horizontally over the sidebar to move between Spaces, including while the
search bar (`⌘T`) is open.
Click the Space buttons in the sidebar footer for the same sliding change, including
between profiles. Each button shows a rounded highlight on hover. Reduce Motion and
Battery Saver keep click changes immediate.

Incognito uses a temporary identity of its own, with a glasses icon and a near-black
theme. It inherits no saved profile's Spaces, history, passwords, or extensions, and
its browsing data and download records are not restored after quitting.

Camera and microphone requests open a sheet on the requesting window with **Allow Once**,
**Always Allow**, and **Don’t Allow**. Allow Once lasts until the tab navigates or closes.
Saved choices belong to the requesting origin and profile; private-tab choices stay in
memory and disappear when that tab closes. Site Controls shows temporary grants and lets
you return each device to Ask.

Settings → Passwords lets you search by website and username, add, edit, reveal,
copy, and delete saved logins. Add/edit forms can generate random passwords of
16, 20, 24, or 32 characters. The autofill chooser shows each account with a masked
password; use the arrow keys and Return to choose, or Escape to dismiss. Save and
update prompts show labeled credentials with a password reveal control. Credentials
stay in the local macOS Keychain and are scoped to the
profile; private browsing does not use saved passwords. The bookmark manager
supports folders, search, bulk actions, and HTML import/export.

Some features depend on macOS services, site behavior, or a signed distribution
build. The [known gaps](#known-gaps) section gives the practical limits.

Capture part of a page with **⌘⇧2**, **File → Capture a Portion of This Page**,
the camera row in Site Controls, or by searching for **Capture** in the command
palette. Click a highlighted element or drag a rectangle over the visible page;
**Escape** cancels. **Return** captures the highlighted region or the visible page.
The preview offers **Copy**, **Save PNG**, **Share**, and **Add to Easel**. In an ordinary
browser window, **Add to Easel** saves the region with its source link to a new or existing
board and opens that board's tab. Captures use WebKit's page
pixels at the display's resolution and need no screen-recording permission. An
embedded frame is selected as a whole; custom drags can crop inside it. Captures
are saved only when you choose an output action, including in private windows.

Battery Saver lives in **Settings → Advanced → Performance**. Choose **Off**,
**Automatic** (below 20% battery while unplugged), or **Always On**. While active,
eligible idle tabs sleep after five minutes, hover link previews pause, and sidebar
motion is reduced. Active pages, pinned tabs, media/Picture in Picture, private tabs,
and unfinished forms keep their existing suspension protections. State changes show
a temporary green lightning popup at the page's top right, with an **Edit this setting**
button. Hovering keeps the popup visible; sleeping tabs reload when selected. The mode respects
the existing idle-suspension preference and preserves an already shorter timeout.

### Saving profiles

Profile save failures appear in browser windows and Settings → Profiles. Unsaved
profile names, colors, new profiles, and selection changes stay in memory; **Retry
Save** writes their latest state. Quitting retries them first and asks before
discarding changes that still cannot be saved. A failed profile deletion keeps its
data and must be requested again. Failed Space changes retain the last saved list;
check storage and folder access, then repeat the change. **Data Folder** helps
locate files for recovery. An unreadable `profiles.json` is preserved: restore it
from a backup, then restart Vane before editing profiles.

### Appearance and icons

Settings → Icon offers Normal, Dark, Galaxy, Candy, Neon, Fluted Glass,
Fluted Glass Dark, Schoolbook, and Luminous. The choice persists across launches and changes the running
app's Dock and Finder icons, including while Vane is quit. Minimized-window previews
also use the selected icon and update when the choice changes. A signed helper stamps
the containing app bundle outside the browser sandbox; read-only or translocated
copies retain the live Dock choice and restore it on launch. The bare SwiftPM
executable has no bundled icon catalogue; build `Vane.app` to use these finishes.

### Easels

Easels open as native tabs inside the browser. Choose **New Easel** from the sidebar's
**+** menu, type **New Easel** in the command palette (`⌘T`), or use **File → New Easel**
(`⌥⌘E`). New boards are pinned in the current Space and return after relaunch. Find
all saved boards under **Library → Easels** or **Window → Show Easels**; opening a board
already in this Space focuses its existing tab. Closing or unpinning a tab keeps its
board in Library. **File → Capture Page to Easel** (`⇧⌘E`) collects the visible webpage
into the most recently used Easel in this Space, or the latest saved board, with its
source link. Boards belong to the browser window's profile and save locally after
each edit. Private windows cannot create boards or save captures.
To move a Space to another profile, remove its Easel tabs first; their boards stay
in the original profile's Library. Export/import a board to copy it to another profile.

The centered toolbar follows Excalidraw's tool order: selection, rectangle, diamond,
ellipse, arrow, line, drawing, text, and image. Click an object once to select it;
drag anywhere inside its box to move it, including the empty interior of an outlined
shape. All four corner handles resize. Double-click text to edit it inline, or a
rectangle, diamond, or ellipse to add its label. With the Text tool, drag out the text
box before typing, or click for a default size. Colors, shape fills, stroke widths,
and text sizes live in the left panel. Text supports Excalidraw's bundled Excalifont,
normal and code faces, and left/center/right alignment. Shapes offer sharp/rounded
edges, solid/dashed/dotted strokes, solid/hachure/crosshatch fills, three sloppiness
levels, and opacity. The hand tool pans the canvas; the lock keeps
a drawing tool active. Tool shortcuts are shown in the toolbar. Arrow keys nudge a
selected item (Shift moves ten points), Enter edits its text, and ⌘D duplicates it.
Notes, links, and clipboard paste are in the **…** menu. Double-click an image to edit
its caption or crop it. Undo/redo and zoom controls sit at the bottom left.
Choose Select to move items after drawing. Scroll in either direction
and choose a zoom level. New items appear near the current canvas viewport.
Standard Undo/Redo work on the board and inside its text editors.

A web capture's play button opens its source page as an interactive live view using
that profile's cookies and content blocker. Pause returns to the saved image. Live
views are temporary, limited to four at once, and stop when switching boards or
leaving the Easel tab or closing the window. They show the source page rather than a live cropped region;
permission prompts, popups, password autofill, and downloads belong in browser tabs.

The `…` menu duplicates or deletes a board, exports a PNG, or exports an editable
JSON document with embedded images. **Library → Easels** shows a searchable card
grid; each card’s **… → Delete Easel…** removes the local board after confirmation.
Import JSON from the Library’s bottom **…** menu. The
canvas is 6,000 × 4,000 points; a board holds up to 256 items, and PNG export scales
the entire occupied canvas to at most 4,096 pixels. Easels do not include cloud
sharing or collaboration.

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

While hovering a webpage link, hold a modifier to see where clicking will open it:

| Link gesture | Result |
| --- | --- |
| `⌘`-click or middle-click | New background tab |
| `⇧⌘`-click | New tab, focused immediately |
| `⌥`-click (also `⌥⇧`) | Split View beside the source page, up to four panes |
| `⌥⌘`-click (also `⌥⇧⌘`) | Little Vane |
| `⇧`-click | Peek, including from pinned and favorite tabs |

Settings › Links can disable the Little Vane and Shift-click Peek gestures.
With Little Vane disabled, `⌥⌘` follows the normal Command-click tab behavior.
The automatic Peek preference for links leaving pinned sites is independent.
Shift-hover previews still require Previews to be enabled; holding Command or
Option hides the preview so it does not cover the opening hint. Floating windows
keep their existing one-page behavior and do not grow Split Views.

## Extension permissions

Choose **Install Extension…** and select an unpacked MV2/MV3 folder. Before it loads,
Vane lists the requested capabilities and website access. Cancel saves nothing.
Approvals belong to that folder in that profile; private profiles cannot install extensions.

On launch, Vane compares the folder's current requested access with its last approved
set. Added capabilities or website patterns require review, and declining leaves the
extension disabled. Choose **Install Extension…** again to review and enable it later.
Existing installations require one review when first opened with this version. Removing
an extension clears its saved approval. Runtime requests for additional access still ask;
those grants last for the current extension session.

Unpacked folder changes are checked when loaded, normally on the next launch. Vane does
not monitor or package those folders; only install code you trust. Location, screen sharing,
and broader real-site permission lifecycle coverage remain separate readiness work.

Focused regression checks:

```sh
swift test --filter 'ExtensionConsentTests|ExtensionAccessLifecycleTests|SitePermissionTests'
```

## AI providers and your own keys

Settings → Max lets you choose Apple (on-device), Groq, OpenAI, OpenRouter, or an
OpenAI-compatible HTTPS API. For a cloud provider, enter its model ID, paste your own
API key, choose **Save Key**, then **Test Connection**. Groq defaults to
`openai/gpt-oss-20b`. Cloud providers may charge for usage or impose quotas.
Custom providers need a base URL such as `https://api.example.com/v1` and support for JSON chat completions.

Every person uses their own key. Keys are stored as local, non-synchronizing macOS
Keychain items, separately for each provider and custom endpoint. No key is bundled
with the browser, committed to the repository, or sent through a Vane server. Test
instances use separate credential namespaces. **Remove Key** deletes the selected
provider's local credential.

Cloud AI handles pinned tab names, download names, and tab grouping. It sends titles,
hostnames, and download naming metadata (with URL queries and fragments removed) to
your chosen provider; it does not upload file contents. Private windows never use cloud
AI. Page summaries continue to use Apple's on-device model. Cloud requests are bounded,
cancellable, and fall back to ordinary title cleanup and grouping on errors or quotas.

The cloud transport checks use an offline HTTP fixture:

```sh
scripts/check-cloud-ai.sh
scripts/check-cloud-ai.sh --keychain # optional isolated local Keychain integration
```

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

The project has one Swift executable target, an XCTest target, and inline checks
run through `selfcheck`. Routine CI builds the debug configuration, runs the pure
checks and XCTest regressions, checks icon selections and cloud AI behavior, tests
CLI import errors and workflow fixtures, assembles the debug app, and exercises
the DMG packager and update installer. Debug builds avoid whole-module release optimization on every change. CI caches `.build` by macOS
architecture, Swift/Xcode/SDK versions, and package/source hashes, and cancels
superseded runs for the same branch or PR. SwiftPM still validates the build on
every cache hit. A timestamp snapshot in the cache restores the previous modification
time only when an input's SHA-256 still matches, letting unchanged files stay
incremental across fresh checkouts. Pull requests only restore caches; successful
`main` checks save them and retain the two newest Swift debug caches. The release workflow builds and smoke-tests the optimized app;
its build products are never cached because they can contain the OAuth secret.

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
```

`swift test` covers search typing and cancellation, link gestures and previews,
Space switching and deletion, tab ordering, Battery Saver, media permission popups and
grant lifetimes, Easels, page capture,
and other browser UI behavior. Search fixtures include a large history database,
keyboard selection, live history changes, and private windows. GitHub credential
regressions exercise the real Live Folder response handler with an isolated
credential-storage fixture:

```sh
swift test --filter 'LiveCredentialTests|GitHubRenewalTests'
python3 scripts/check-live-credential-persistence.py
```

A rejected GitHub credential stays in Keychain while Edit Live Folder offers
reconnection. Ordinary refreshes continue, and a successful retry clears the warning.
Only explicit sign-out or other user-requested credential removal deletes it.
For a real-session check, reconnect in the installed app, quit normally, relaunch the
same signed build, and refresh the folder. If authentication fails again, Console's
`[vane] GitHub` messages distinguish missing/inaccessible Keychain credentials from
HTTP 401 responses and record GitHub's request ID. These diagnostics never log tokens
or response bodies.

OAuth sign-ins store the access token, refresh token, and expiry together in the same
scoped Keychain item. Live Folders renews shortly before the access token expires and
can renew after an early rejection, then retries the API request once. Concurrent
folders and app processes sharing a profile serialize token rotation and use the
persisted replacement. A temporary network or Keychain failure retains the credentials;
an unsaved rotated pair is kept in memory while Vane retries its Keychain write.
The regression tests advance expiry and inject OAuth/network/storage responses without
using a real GitHub account. The fresh-process Keychain check verifies both tokens and
expiry survive relaunch with disposable fixture credentials.

Sign-ins saved by older builds need one reconnect because those builds discarded the
refresh token. A revoked or expired refresh token also needs reconnection. Source builds
without the OAuth client secret can still use personal access tokens; they cannot renew
a web-flow OAuth grant. A signed release includes the secret required for renewal.
For a live check, reconnect using that release, quit/relaunch, and refresh after eight
hours: the folder should renew automatically, and Console should record
`[vane] GitHub OAuth credential renewed` without requiring another sign-in.

Before shipping, also check the release configuration:

```sh
swift build -c release
./.build/release/vane selfcheck --pure
./make-app.sh
./scripts/test-build-dmg.sh
```

For a logged-in macOS 26 desktop, the smoke script creates a temporary signed
app and isolated test profile, then runs real WebKit assertions:

The smoke run also reports first-page setup and 100-tab session restoration timings.
It checks that parked rows need no web views, selecting a row creates its page, and
global settings and extension metadata queries keep background rows parked.

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

- A [public-demo compatibility pass](docs/REAL-SITE-COMPATIBILITY.md) verified
  password-session navigation, print-to-PDF, local WebRTC calls, screen-capture
  startup, clear HLS and FairPlay demo playback, and basic Excalidraw/VS Code editing
  on macOS 27 in an ad hoc signed debug build. The file-picker failure was fixed
  and a synthetic upload reached the public demo server in a follow-up check.
  Passkey authentication was unavailable in the original fixture. Provider sign-ins, subscription
  streaming, cross-network calls, broader permission lifecycles, and macOS 26 /
  notarized-release coverage remain unverified. See the matrix for exact scope.
- Passkeys are **known pending** until Apple approves the managed macOS browser
  entitlement and Vane is signed with a matching provisioning profile. A Developer
  ID certificate alone does not enable this capability. Successful registration
  and sign-in still need testing after provisioning and user authorization.
- Password autofill is heuristic. Multiple saved accounts have a chooser, but
  unusual, multi-step, or embedded login forms may still need manual entry.
- Content blocking supports a documented subset of EasyList syntax. Filter
  lists added from disk do not update on a schedule.
- Data does not sync between Macs. Imports do not bring over browser cookies or
  signed-in sessions.
- Location and screen-capture permission work and broader real-site permission lifecycle
  verification remain deferred.
- Extensions load from unpacked MV2/MV3 folders. This does not guarantee Chrome
  extension compatibility. Installation requires permission review, and expanded
  manifest access requires another review before the extension loads.
- Some browser features, including the in-app inspector, depend on WebKit behavior
  or private APIs that can change with macOS releases.
- Distribution readiness requires a real signed and notarized candidate,
  clean-Mac install and upgrade checks, and broader compatibility testing.

The tracked engineering work is in
[browser readiness](docs/BROWSER-READINESS-TODO.md).

## Project map

| Path | Purpose |
| --- | --- |
| [`Sources/Vane/main.swift`](Sources/Vane/main.swift) | CLI dispatch and application startup. |
| [`Sources/Vane/AppLifecycle.swift`](Sources/Vane/AppLifecycle.swift) | Application delegate, Dock actions, and window lifecycle. |
| [`Sources/Vane/Engine.swift`](Sources/Vane/Engine.swift) | Tabs, WebViews, navigation, and WebKit delegates. |
| [`Sources/Vane/SharedTabs.swift`](Sources/Vane/SharedTabs.swift) | Shared Space tabs and live-page ownership between windows. |
| [`Sources/Vane/UI.swift`](Sources/Vane/UI.swift) | Main browser window and SwiftUI controls. |
| [`Sources/Vane/Profiles.swift`](Sources/Vane/Profiles.swift) | Profile and Space state, paths, and isolation. |
| [`Sources/Vane/Store.swift`](Sources/Vane/Store.swift) | SQLite history and bookmarks. |
| [`Sources/Vane/LibraryWindow.swift`](Sources/Vane/LibraryWindow.swift) | Downloads, media, archives, Spaces, and Easels browsing. |
| [`Sources/Vane/Easels.swift`](Sources/Vane/Easels.swift), [`EaselWindow.swift`](Sources/Vane/EaselWindow.swift) | Saved board data and the editing canvas. |
| [`Sources/Vane/PageCapture.swift`](Sources/Vane/PageCapture.swift) | Element and region selection, page snapshots, and capture outputs. |
| [`Sources/Vane/BatterySaver.swift`](Sources/Vane/BatterySaver.swift) | Battery-aware suspension and reduced preview/motion policy. |
| [`Sources/Vane/AppIcon.swift`](Sources/Vane/AppIcon.swift), [`AppIcons/`](AppIcons/) | Dock icon selection and bundled Icon Composer assets. |
| [`Sources/Vane/CloudAI.swift`](Sources/Vane/CloudAI.swift), [`AIKeys.swift`](Sources/Vane/AIKeys.swift) | Provider requests, privacy rules, and local API-key storage. |
| [`Sources/Vane/Passwords.swift`](Sources/Vane/Passwords.swift) | Keychain integration, autofill, and the selfcheck runner. |
| [`Sources/Vane/Updater.swift`](Sources/Vane/Updater.swift) | Release checks and authenticated XPC installation; the signed installer checks Gatekeeper and removes update quarantine before the locked, crash-recoverable swap. |
| [`Tests/VaneTests/`](Tests/VaneTests/) | XCTest browser and UI regressions. |
| [`scripts/`](scripts/) | Browser smoke, release-candidate, packaging, and integration checks. |

## License

MIT. See [LICENSE](LICENSE).
