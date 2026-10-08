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

Search ranks exact page titles and addresses before prefixes, partial words, and
fuzzy letter matches. Accents and case do not affect matching. Bookmarks, visit
frequency, and recency break relevance ties. Tab search searches the current
profile and offers an **All open Spaces** filter for the live tabs it can access.
History (`⌘Y`) offers explicit profile selection and Today, Yesterday, Last 7 days,
and Last 30 days filters. Search results show relevance first and include each
visit's date; an empty search groups visits by day. History has no Space filter
because visits do not store which Space they belonged to. Private windows show
neither saved history nor other windows' tabs. Searches run off the input thread
and discard superseded results.

Windows in the same Space share tabs. When both show the same tab, the focused
window holds its live page and the other shows a gray snapshot. Switching windows
preserves input, scroll position, and history; closing a tab removes it from every
window. Each window keeps its own selection. Private and Little Vane windows keep
their own pages. Split View shows two to four pages side by side or stacked, with
resizable dividers. Peek opens a link over the current page; Little Vane opens it
in a separate compact window.

Showing or hiding the sidebar applies across all Spaces in that window, including
Spaces in other profiles. Each window keeps its own sidebar visibility.

Drag a sidebar tab to reorder it: the white line marks the nearest insertion gap,
and the rows stay in place until you release. The line fades in once and stays visible
while moving between gaps. The held ghost matches the tab row.
Hold Option while dropping onto the middle of another tab to make a split view.
Dropping into a closed folder highlights it and opens its icon while you hover.

**Tidy Tabs** first opens a review sheet. Rename its proposed folders and untick
pages you want to leave loose, then choose **Apply Groups**. A changed page or Space
requires a fresh proposal. Tidy preserves pinned tabs, favourites, existing folders,
split panes, and custom tab names; **Undo Tidy Tabs** takes the grouping back.

Choose **Tabs → Organize Tabs…** or the Space menu's **Organize Tabs…** to search
and select Today tabs across the current profile's Spaces. Copy their links, move
them to another Space as Today tabs, or archive the selection. **Duplicates only**
compares complete URLs, including query strings and fragments. **Select Extras**
offers a selection for review; pinned tabs, favourites, named tabs, and tabs in use
are preferred as keepers. Untick or tick individual copies, then choose **Archive
Selected Copies**. Cleanup requires at least one copy to remain. Locked-folder
contents are hidden; pinned tabs, favourites, and split panes are protected from
bulk moves and archives. **Undo** in the sheet, the toast, or **Tabs → Undo Tab
Organization** restores the last action for that profile, including folder order
and saved page state, while the affected tabs and folders have no later changes.
Reduce Motion and Battery Saver keep list and selection changes immediate.

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

Starting a download sends a small marker from the page into the Library bucket.
The bucket briefly shows the file type's icon on arrival. Reduce Motion and Battery
Saver show the icon immediately without the flight.

Pinned tabs keep their saved name as you navigate within them. When a pinned tab
leaves its saved page, its sidebar row shows `/` before its title and offers
**Return to Pinned Tab**; returning
loads the pinned URL again. Favorites belong to a profile, while pinned and Today
tabs belong to a Space. Library lists Spaces across all profiles.
Swipe right to left within the Library panel to close it, or use Escape or its
back button. From the leftmost Space, swipe left to right over the sidebar to
open Library at its last-used section. Swipes over page content stay with the page,
including back and forward navigation. Vertical scrolling still scrolls the Library.

Choose **Page Actions → Save for Offline** or **View → Save for Offline** on a readable
article. **Library → Reading Queue** holds this profile's saved copies, searches their
article text as well as titles and links, and offers All, Unread, and Read filters.
Open a saved copy without a connection, explicitly mark it read or unread, or remove
it to reclaim storage. The queue shows its article count and storage usage. Opening
does not automatically mark an article read. Saving an already saved URL keeps the
existing copy; remove it and save again to capture a newer version.

Saved Reader labels the **Saved copy**, capture date, and source, reuses Reader's
reading preferences, and offers **Open Live Page** separately. Saves publish
atomically in local profile storage and participate in complete backups and restore.
Private browsing cannot persist or access the queue. Unsupported pages and failed
saves explain the problem. Images are captured where practical through anonymous
requests; authentication, size limits, or failed downloads can leave a text-only
copy with a missing-image notice. Saved views never fetch missing images from the
live site. The queue focuses on article text rather than interactive pages or PDFs;
it supports up to 1,000 articles per profile and 20 MiB per article. Backup exports
retain their 512 MiB total limit and report a failure without omitting saved content.

Hover the Space card to reveal its chevron and `…` menu. Click the card to collapse
or expand its pinned tabs; Today stays visible. Double-click its name to rename
the Space. Each window remembers the collapsed state for each Space while open.
Swipe horizontally over the sidebar to move between Spaces, including while the
search bar (`⌘T`) is open.
Click the Space buttons in the sidebar footer for the same sliding change, including
between profiles. Each button shows a rounded highlight on hover. Reduce Motion and
Battery Saver keep click changes immediate.

Choose the Space menu → **Save Space as Template…** to save a named workspace.
**Space Templates…**, also available as **New Space from Template…** in the creation
menu, previews the current profile’s saved setups and creates a new Space. Templates
preserve pinned and Today tab order, duplicate pages, custom names, nested folders,
Space appearance, and supported split layouts including divider sizes. Rename a
template, update it from the current Space after reviewing its contents, or delete it;
already created Spaces keep their own contents.

Locked-folder contents require macOS authentication before saving, previewing, or
recreating them. New folders retain their locks and receive fresh identities.
Templates save addresses and layout without cookies, credentials, website storage,
or WebKit navigation state; pages can still use their profile’s existing sign-ins.
Credential-like URL parameters and URL userinfo are removed. Blank tabs, files, and
local Easel documents are excluded and counted in the preview. Live folders become
ordinary folder snapshots, and Favourites remain shared by the profile. Private and
Little Vane windows cannot save templates. A failed save leaves the previous version
safe, and a failed creation leaves no partial Space. Template files use the same
atomic persistence and profile filename conventions as Spaces for backup/restore.

Incognito uses a temporary identity of its own, with a glasses icon and a near-black
theme. It inherits no saved profile's Spaces, history, passwords, or extensions, and
its browsing data and download records are not restored after quitting.

Camera and microphone requests open a sheet on the requesting window with **Allow Once**,
**Always Allow**, and **Don’t Allow**. Builds made with Xcode 27 also offer location
choices and a Location row on macOS 27. Allow Once belongs to the requesting document
and expires when it navigates or closes. Embedded camera, microphone, and location
requests fail closed because the public APIs do not identify their original document
reliably. Saved choices belong to the requesting main frame’s exact origin and profile;
private choices stay in memory in that private tab. Site Controls returns decisions to Ask or Block and stops
camera/microphone capture for the affected device. Revoking location reloads pages
using its decision; location watches end when reload completes. Cancelling the reload
can leave existing watches alive until the document is replaced.

These are Vane’s **site decisions**. macOS independently authorizes Vane to access
camera, microphone, Location Services, and screen recording; Allow in Vane cannot
override a macOS denial. Screen-sharing selection and permission remain managed by
WebKit and macOS. Vane has no supported screen-sharing persistence or per-source
revocation API. See [permission lifecycle and platform limits](docs/SITE-PERMISSIONS.md).

Settings → Passwords lets you search by website and username, add, edit, reveal,
copy, and delete saved logins. Add/edit forms can generate random passwords of
16, 20, 24, or 32 characters. The autofill chooser shows each account with a masked
password; use the arrow keys and Return to choose, or Escape to dismiss. Save and
update prompts show labeled credentials with a password reveal control. Credentials
stay in the local macOS Keychain and are scoped to the
profile; private browsing does not use saved passwords. Username-first sign-ins keep the
selected account through form replacement or the next same-origin password page. Fields
revealed or mounted by a site are discovered automatically, and same-origin embedded
login forms use their own fields and chooser anchors. Hidden fields and one-time codes
are excluded from filling; cross-origin and opaque sandbox frames cannot receive credentials.
The bookmark manager
supports folders, search, bulk actions, and HTML import/export.

Some features depend on macOS services, site behavior, or a signed distribution
build. The [known gaps](#known-gaps) section gives the practical limits.

Choose **Site Controls → Boost This Site** to customize a website while viewing it.
The native Boost editor previews fonts, text size, background/text/link colors, and
custom CSS as you edit (CSS `@import` is not supported). **Zap an Element** highlights what is under the pointer;
click to hide it, select **Undo** or a saved selector's restore button to bring it
back, and press **Escape** to finish. Hidden-element rules also apply to content
added later. A site's markup changes can require selecting an element again;
iframes can be hidden as a whole, and shadow-root contents are not edited.

Boosts save locally per profile and exact website origin (scheme, host, and port).
Subdomains have separate Boosts. Private tabs keep their own temporary changes.
**Code → JavaScript** offers an explicit **Enable JavaScript** switch and **Apply
Script** button. Enabled scripts run once after each new document loads; editing
code alone does not run it. Script errors appear in the editor. Disabling or
resetting prevents future runs; reload the page to remove effects already made
by a script. **Reset Boost** restores the site's visual defaults, and
**Settings → Profiles → Site Permissions → Reset Boosts…** removes all Boosts in
that profile. Reduce Motion and Battery Saver keep editor transitions immediate.

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

### Content blocking and filter subscriptions

Settings → Privacy and Security → Content Blocking separates **Import from Disk**
(local snapshots, never downloaded again) from **Subscribe by URL** (HTTPS lists).
The built-in starter list stays available offline. Existing imported snapshots and
legacy file references are preserved. Sources are shared across profiles; the main
blocking switch and site exceptions belong to each profile.

URL subscriptions update daily while Vane is running. Vane checks overdue lists at
startup, after wake, and hourly; failed attempts retry after one hour. **Update Now**
or a list's **Update** button retries immediately. Status shows updating, last/next
check times, and failures. Conditional HTTP requests use the accepted list's ETag
and Last-Modified values. Downloads use an ephemeral session, not browsing cookies,
and are limited to 8 MB of UTF-8 text per list.

Vane compiles the combined candidate using WebKit's public `WKContentRuleListStore`
before saving a changed subscription. Download, compilation, or storage failures
retain the accepted source and last working compiled rules, including across
relaunch. A saved base-rule snapshot also lets new site exceptions take effect when
a legacy source is missing. URL text and metadata live together in an atomic
`FilterSubscriptions/subscriptions.json` document; disk imports stay in `FilterLists`.
The feature does not depend on a managed Apple entitlement.

**Site Controls → Block Ads on This Site** changes an exception for the exact host
and reloads the page after rules attach. Exceptions also cover that page's embedded
requests and cosmetic rules; subdomains have their own choices. **Filter Lists and
Diagnostics** opens update status, unsupported rules, and saved exceptions. Resume
blocking there to remove an exception, then reload other open pages. Subscription
updates preserve exceptions; private-window choices are not saved as preferences.
Private compiled variants use a separate transient WebKit store, removed on normal
quit; the next launch sweeps crash leftovers while preserving other live Vane instances.

The converter supports a subset of EasyList: host/start/end anchors, wildcards,
network exceptions, supported resource/party options, positive-only or negative-only
domain restrictions, and ordinary CSS hiding. Resource types follow WebKit's
vocabulary: subdocuments use `document`, and XHR/WebSocket/ping use `raw`.
Regex rules, scriptlets, procedural selectors, cosmetic exception variants, unknown
options, mixed/invalid domain restrictions, and rules inside conditional branches
are skipped. Unbalanced conditional directives reject a subscription update, and
each source has independent preprocessing state. **Unsupported Rules** reports totals by reason and the first 20 samples
with line numbers; local imports can be inspected separately. Vane does not claim
full uBlock Origin or AdGuard compatibility or expose request-by-request block counts.

Focused regression checks (including real WebKit network and cosmetic behavior):

```sh
swift test --filter 'BlockerTests|BlockerSubscriptionTests|BlockerWebKitTests'
./.build/debug/vane selfcheck --pure
```

### Saving profiles

**Settings → Profiles → Website Data** (also in Privacy and Security) lists the
selected profile’s stored website data. Search for a site, select its available
categories, and choose **Clear Selected Data…**. **Site Controls → Clear Site Data…**
opens the same view focused on the current site. WebKit groups sites by registrable
domain, so an entry can include subdomains. Public WebKit APIs do not expose reliable
per-site byte counts on macOS 27; the view labels disk usage unavailable.

Clearing cookies or storage can sign you out or remove offline website work. Close
that site’s tabs first: live pages can retain state and recreate data. The view waits
for removal, fetches a fresh snapshot, and reports retained data or an unverified
result instead of announcing success early. A slow operation remains pending.
History, bookmarks, saved passwords and Vane’s site settings are kept. Private site
controls inspect only that tab’s temporary store, without opening a saved profile’s
store. Bulk browsing-data clearing also waits for WebKit completion and keeps shared
app-opening permissions.

```sh
swift test --filter 'WebsiteDataTests|WebsiteDataWebKitTests|ProfilePersistenceTests'
```

Settings → Advanced → **Backup and Restore** exports one `.vanebackup` file with all
regular profiles, Spaces, saved tabs and sessions, bookmark folders and bookmarks,
history, Space templates, offline articles with captured images and read state,
settings (including Reader preferences and profile-scoped site Boosts), imported
blocking lists, and Easels with embedded images. Backups
are unencrypted and limited to 512 MB; oversized backups fail without omitting data.
Passwords and tokens in Keychain, cookies and website sign-ins/storage, downloaded
files, caches, and external extension folders are excluded. External folder choices
are remembered, but another Mac may require you to select those folders again.

**Restore Backup…** validates the file and shows its date, profiles, item counts, and
current saved-library totals before replacing anything. Cancel leaves the library
alone. **Restore and Restart** preserves a local recovery point, then restores all
saved profiles and settings during a controlled restart. It replaces the library;
it does not merge it. An interrupted restore rolls back before normal startup.

Vane creates a recovery point after startup and checks hourly while running, saving
another only when saved data changes. The latest ten completed points are kept under
the data folder's `Recovery/Points`, including points made before restores. The last
healthy point is protected if damaged originals need preserving. Preview and restore
them from the same Settings section. A write failure keeps previous points and shows
an error with Retry. These local copies share your disk: export to another disk for
protection against disk loss. **Erase Everything…** removes local recovery points too.

Focused backup validation:

```sh
swift test --filter 'DataIntegrationTests|Backup.*Tests|SpaceTemplate.*Tests|ReadingQueue.*Tests|ProfilePersistenceTests|EaselTabTests|HistoryPersistenceTests'
```

The [cross-feature integration evidence](docs/DATA-INTEGRATION.md) records the
populated round trip, interruption recovery, profile/private checks, and limits.

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

### Reader

Enter Reader from Page Actions or **View → Reader Mode**. **Page Actions → Reading
Preferences** offers text size (13–32 pt), serif type, compact/standard/relaxed line
spacing, and narrow/standard/wide reading columns. Spacing and width are also in
**View → Reading Preferences**. Preferences save locally and apply immediately to
the current Reader; new Reader views use the saved choices. These preferences are
shared across profiles and private Reader views and included in complete backups.
Changes animate briefly
unless Reduce Motion or Battery Saver is active. The header links to the source
article, and article links remain usable.

Extraction retains scored sibling sections, prose in legacy table layouts, technical
data tables, code indentation, and lazy image captions while omitting hidden content
and navigation. It remains heuristic: unavailable/paywalled text, embedded frames,
and articles below the 140-word threshold are not recovered. Exit Reader reloads the
original page; it does not add a history entry.

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
Notes, links, and clipboard paste are in the **…** menu. New captures are selected when their board opens. Click an image's pencil,
**Annotate Image** in its context menu, or the selected image's properties to pause
its live source and activate the existing drawing tool with the tool lock on. Draw
on the saved capture, or choose arrows, shapes, and text in the same toolbar. Choose
Select or press Escape to move items afterwards. Double-click an image to edit
its caption or crop it. Undo/redo and zoom controls sit at the bottom left.
Choose Select to move items after drawing. Scroll in either direction
and choose a zoom level. New items appear near the current canvas viewport.
Standard Undo/Redo work on the board and inside its text editors. Annotations remain
independent editable objects; moving or cropping an image does not transform its
annotations with it. Image import preserves the available pixel resolution while
keeping the canvas card compact; images beyond 8 MiB PNG, 16,000 pixels on either
side, or 32 million pixels are refused rather than silently downsampled. Board PNG
export still uses the 4,096-pixel limit below.

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
| Move between page and browser controls | `F6` or `⇧F6` |
| Search tabs | `⇧⌘A` |
| Search commands | `⇧⌘P` |
| Open Library | `⇧⌘L` |

Shortcuts can be changed in Settings. The menu bar shows the current bindings,
including numbered tab selection and search commands. Choose **Prefer Website**
for a shortcut to leave it with a focused webpage; the command remains available
from the menu and while browser controls have focus. Option-only shortcuts also
leave character entry and caret movement with a focused text editor.

Use **F6** (or **Shift-F6**) to move between the page and browser controls, revealing
the sidebar if needed. Use **Tab** and **Shift-Tab** to move through browser controls. Sidebar tabs,
favourites, folders, Spaces, split panes, and the address pill show a focus outline;
**Return** or **Space** activates the focused control. Enable macOS **Keyboard
navigation** to include native buttons and menus in Tab navigation. Search results
use **Up/Down** and **Return**; **Tab** keeps its site-search and actions behavior.
**Escape** dismisses search or Find and returns focus to the page when no other
control has taken it. **⌘F** refocuses an already-open Find field. VoiceOver can
activate sidebar items directly and use their Actions menu for secondary commands.

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

## Extensions and permissions

Choose **Extensions → Install Extension…** and select an unpacked MV2/MV3 folder.
Before loading, Vane checks its manifest and referenced scripts, popups, options pages,
and rulesets, then lists the capabilities and website access for consent. Cancel saves
nothing. Approvals and extension data belong to that installation in that profile;
private profiles cannot install extensions.

**Extensions → Manage Extensions…** (also in Settings → Advanced) lists enabled,
disabled, and failed installations in the current profile. **Access & Diagnostics…**
shows the folder, WebKit error details, compatibility limitations, and currently granted
access. Missing or unreadable resources name the manifest entry and file to repair.
Unsupported capabilities are disclosed before installation as well as in diagnostics.

**Update from Folder** validates current files and reviews added capabilities or website
patterns before replacing the context. **Retry** does the same for an inactive installation.
A failed or declined update stops the extension, closes its options/popup windows, and
removes its active toolbar controls while retaining its bookmark, consent, installation
identity, settings, and saved pin for recovery. Repair the folder and retry. Vane does
not keep a backup of unpacked code, roll back folder edits, or monitor folders automatically;
folder changes are otherwise checked on the next launch. Only install code you trust.

**Disable** stops the context and its extension pages, and persists across restart.
**Enable** checks the folder and reuses unchanged consent and `storage.local` identity.
**Remove** clears the bookmark, consent, identity, disabled state, and pin, including for
failed installations; reinstalling uses a new identity and cannot inherit old settings.
Unavailable saved folders remain recoverable when their disk or access returns, and can
be removed while unavailable. Bookmarks that follow a moved folder carry its consent,
identity, disabled state, and pins to the new location on restart. Disabled installations
keep their saved pin; Manage Extensions lets you unpin them to free one of three slots.
Existing installations without a saved approval require review before loading.

Runtime requests ask separately. Optional capabilities and sites are not granted by
installation consent. Runtime grants last for the current context session: update,
disable, or quitting ends them. **Revoke Additional Access** clears additional runtime
grants and denials; required manifest access stays approved. Disable the extension to
stop all access. Requests pending when an extension is removed or disabled fail closed.
WebKit enforces permission expiration dates; manifest consent is separate from runtime grants.

Vane uses Apple's WebKit WebExtension APIs, not Chromium. On macOS 27, isolated synthetic
fixtures exercise MV2 background scripts and MV3 service workers, runtime messaging,
`storage.local`, action badges/popup declarations, content-script origin/profile isolation,
and runtime permission grant, rejection, revocation, expiration, and restoration.
This does **not** establish general Chrome-extension or Chrome Web Store compatibility,
nor certify arbitrary extensions, real-site behavior, every API, or full popup interaction.
Vane does not provide native messaging hosts, extension page-menu items, extension keyboard
shortcuts, replacement browser pages, side panels, developer-tools panels, omnibox keywords,
or Chrome OAuth integration. Other API availability depends on the installed WebKit.

Focused regression checks:

```sh
swift test --filter 'ExtensionConsentTests|ExtensionAccessLifecycleTests|ExtensionCompatibilityTests|ExtensionManagementTests|ExtensionRuntimePermissionTests|ExtensionPinsTests|SitePermissionTests'
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

Import from Arc reads local SQLite snapshots and decrypts supported `v10` credentials
using Arc's Keychain Safe Storage key. Passwords keep their scheme and port; autofill
uses HTTPS and matches the full origin. Existing Vane passwords are kept, and duplicate
Arc logins use the most recently modified password (creation time in older schemas).
Session imports preserve HttpOnly, SameSite, Secure, domain, path, and lifetime.
Expired, partitioned, or unsupported cookies are skipped and reported; those sessions
may need a fresh sign-in. No decrypted value is logged or written to an import file.

Password exports contain plain text credentials. Delete a CSV export when you no
longer need it. The same importer is available from Vane's Passwords UI. CSV imports
preserve existing passwords, keep the first successfully saved duplicate, and report
invalid/skipped rows and Keychain write failures. Malformed CSV quoting fails before
any saves. A password export fails if any owned credential cannot be read.

Bookmark HTML retains titles, URLs, whole-second dates and readable folder paths;
nested paths become one `Parent / Child` folder. Native browser bookmark imports
currently retain only URLs and titles. Browser history imports retain each available
visit and deduplicate by URL and timestamp, so repeated imports add nothing. A failure
reading or saving either selected browser category leaves both categories unchanged.
History CSV/JSON files are export formats; they have no user-facing file importer.
See [browser data fidelity and unsupported fields](docs/audits/browser-data-fidelity.md)
for normalization, duplicate rules, synthetic coverage and failure behavior.

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
scripts/test-updater-recovery.sh
python3 scripts/test-updater-transport.py
scripts/test-updater-relaunch.sh
```

For focused password validation on a logged-in macOS desktop:

```sh
swift test --filter 'PasswordAutofillTests|PasswordOriginTests|PasswordChooserLayoutTests|PasswordPopupPresentationTests|PasswordManagerSearchTests|PasswordGeneratorTests'
python3 scripts/check-browser-smoke.py
```

The autofill fixtures exercise real WebKit documents, controlled input events, dynamic
visibility, account continuity, embedded forms, stale chooser targets, and scoped
Keychain reads. Keychain-dependent XCTest fixtures report a skip if storage is unavailable.

For site-permission lifecycle fixtures and a fake display-capture check, see
[Site permissions on macOS 27](docs/SITE-PERMISSIONS.md#validation-and-remaining-platform-coverage).

For download interruption, resume, destination and process-restart fixtures, see
[Download reliability on macOS 27](docs/DOWNLOAD-RELIABILITY.md).

`swift test` covers search typing and cancellation, link gestures and previews,
Space switching and deletion, tab ordering, Battery Saver, media permission popups and
grant lifetimes, requesting-frame ownership and synthetic capture revocation, Easels, page capture,
and other browser UI behavior. Search fixtures include a large history database,
keyboard selection, live history changes, and private windows.

The native History rendering performance budget is a separate, opt-in release
benchmark on a quiet logged-in Mac. It retains its 100 ms limit; hosted debug CI
cannot separate Vane work from window-server activation and timer scheduling.
History correctness, profile isolation, search cancellation and input-thread search
checks remain in the routine test suite.

```sh
VANE_UI_PERFORMANCE=1 swift test -c release -Xswiftc -enable-testing --filter HistoryResponsivenessTests
```

GitHub credential regressions exercise the real Live Folder response handler with an isolated
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
# Opt-in lifecycle measurement: 100 tab/window cycles, 200 parked session rows,
# at least 30s settling and 60s idle sampling (logged-in desktop required).
python3 scripts/check-browser-smoke.py --lifecycle
```

For an opt-in network-dependent public streaming pass on a graphical test Mac:

```sh
python3 scripts/check-browser-smoke.py --public-media
```

This separately samples 90 seconds per clear/FairPlay Shaka demo asset, with
pause/seek/resume and player unload/reload. It uses no service accounts and does
not verify subscription playback, cross-network calls or system capture revocation.
Exact outcomes and limits belong in [the compatibility log](docs/REAL-SITE-COMPATIBILITY.md).

The full `selfcheck` uses a keychain and a window server. Run it locally when
those services are available:

```sh
./Vane.app/Contents/MacOS/Vane selfcheck
```

Updater failure checks use disposable directories and child processes. The headless
recovery suite kills processes at transaction boundaries, verifies retained contents,
and exercises stale records, retries, rollback and cleanup. The loopback transport
suite probes actual URLSession cancellation and interrupted/truncated HTTP responses;
its host is simulated and never bypasses the production GitHub trust policy.

For real signed/notarized input, pass an unchanged release app to
`scripts/test-update-installer.sh`. Developer ID rejection fixtures can be created with
`SIGN_ID=… scripts/make-updater-rejection-fixtures.sh /path/to/release/Vane.app /path/to/new-fixture-directory`,
then tested with `scripts/test-update-installer.sh /path/to/release/Vane.app --fixtures /path/to/new-fixture-directory`.
These deliberately unnotarized copies check identity, version, native architecture,
signature diagnostics and actual Gatekeeper rejection. Never use them as a release.

After coordinating a graphical test slot, native recovery can be checked with
`SIGN_ID=… python3 scripts/test-updater-native.py --app /path/to/signed-new/Vane.app --previous /path/to/unchanged-old/Vane.app --evidence /path/to/evidence`.
`SIGN_ID` is required for pinned Developer ID XPC authentication. Add
`--bootstrap-failure` to cover a signed executable that exits before updater startup,
plus stale and malformed journals. The driver uses unsandboxed staging, Vane’s exact
sandbox identity and the authenticated installer service for isolated restart. It
never starts or cleans browser preferences/profile data itself. Disposable bundles
live under Downloads; the fixture records actual browser environment and exact
process identities, including App Translocation, before cleanup. Isolated restarts
use a detached unsandboxed installer worker and exact child processes;
sandboxed LaunchServices callers drop those overrides, and direct execution from an
inherited sandbox fails before main on macOS 27. The fixture simulates notarization
for the local candidate at the transaction boundary;
actual distribution verification remains the separate installer/release-candidate check.
To test the current XPC helper with an unchanged notarized payload, run
`SIGN_ID=… scripts/test-update-installer-xpc.sh /path/to/current/Vane.app /path/to/notarized/Vane.app`.

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
  A macOS 27.0.1 follow-up covers exact multiple-file/frame submissions, print CSS
  and page ranges, extension storage restoration, decoded media controls, and disk
  session restoration. A standalone signed WKWebView probe reproduces an upstream
  guard fault during directory form submission on macOS 27.0.1, before any POST
  reaches the receiver. Vane cancels folder selection with an explanation on macOS
  27.0; ordinary file uploads remain available. See the matrix for the retained
  failing reproduction, byte-level evidence, and version limits.
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
- Data does not sync between Macs. General browser imports do not bring over cookies
  or signed-in sessions; the dedicated Arc import can copy supported sessions as described above.
- Location site decisions require a build with Xcode 27 and macOS 27. Screen-sharing
  decisions remain WebKit/macOS-managed. Synthetic permission lifecycle checks do not
  establish real-device authorization or native chooser behavior; see
  [permission limits and validation](docs/SITE-PERMISSIONS.md).
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
