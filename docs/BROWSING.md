# Everyday browsing

[Documentation index](README.md) · [Project README](../README.md)

Start here for tabs, Spaces, search, windows, downloads, and media. For saved reading
and visual tools, see [Reading and customization](FEATURES.md).

## First launch

Fresh installations open with a short, skippable welcome to search and Spaces. Finishing
or skipping it leads into browsing; existing installations skip it. Reduce Motion and
Battery Saver keep the welcome still.

Local, debug, and prerelease builds skip the startup default-browser prompt. Stable
release builds packaged with `SIGN_ID` offer it once. You can still use the manual “Make
Vane Default…” action in Settings.

## Tabs and the sidebar

Favourites belong to a profile; Pinned and Today tabs belong to a Space. Today tabs can
auto-archive; find them in Library → Archived Tabs. Use the row’s context menu to pin or
unpin a page.

Showing or hiding the sidebar applies across all Spaces in that window, including Spaces
in other profiles. Each window keeps its own sidebar visibility.

Hover a sidebar tab to see a compact name tooltip and a **Double-click to rename** hint.
Double-click a Today tab, pinned tab, favourite, or split pane to edit its name in
place. Press **Return** to save or **Escape** to cancel; an empty name restores the
page’s title.

Pinned tabs keep their saved name as you navigate within them. When a pinned tab leaves
its saved page, its sidebar row shows `/` before its title and offers **Return to Pinned
Tab**; returning loads the pinned URL again. Favorites belong to a profile, while pinned
and Today tabs belong to a Space. Library lists Spaces across all profiles.

## Reorder, group, and clean up tabs

Drag a sidebar tab to reorder it: the white line marks the nearest insertion gap, and
the rows stay in place until you release. The line fades in once and stays visible while
moving between gaps. The held ghost matches the tab row. Hold Option while dropping onto
the middle of another tab to make a split view. Dropping into a closed folder highlights
it and opens its icon while you hover.

### Tidy Tabs

**Tidy Tabs** first opens a review sheet. Rename its proposed folders and untick pages
you want to leave loose, then choose **Apply Groups**. A changed page or Space requires
a fresh proposal. Tidy preserves pinned tabs, favourites, existing folders, split panes,
and custom tab names; **Undo Tidy Tabs** takes the grouping back.

### Organize and remove duplicates

Choose **Tabs → Organize Tabs…** or the Space menu's **Organize Tabs…** to search and
select Today tabs across the current profile's Spaces. Copy their links, move them to
another Space as Today tabs, or archive the selection. **Duplicates only** compares
complete URLs, including query strings and fragments. **Select Extras** offers a
selection for review; pinned tabs, favourites, named tabs, and tabs in use are preferred
as keepers. Untick or tick individual copies, then choose **Archive Selected Copies**.
Cleanup requires at least one copy to remain. Locked-folder contents are hidden; pinned
tabs, favourites, and split panes are protected from bulk moves and archives. **Undo**
in the sheet, the toast, or **Tabs → Undo Tab Organization** restores the last action
for that profile, including folder order and saved page state, while the affected tabs
and folders have no later changes. Reduce Motion and Battery Saver keep list and
selection changes immediate.

### Move tabs out of folders

After Tidy groups Today tabs into folders, drag a tab or selection into the blank space
below the last row to move it outside the folders at the bottom of Today. That drop area
remains available when the last row is a collapsed folder or the list fills the sidebar.
Dropping onto **New Tab** moves tabs to the top of Today; right-click → **Remove from
Folder** keeps tabs in their section. An empty Today folder disappears. Click and drag
the blank area below Today tabs to move the window.

### Favourites

Drag a tab onto a favourite tile or into the gaps between tiles to add it to Favourites.
Approaching Favourites reveals a drop tile when it is empty; the address pill also
accepts the first favourite. Nearby tiles move aside and the drag preview takes its
destination tile's shape, then transforms back into a row when dragged out. This
previews placement; the order commits only on release. Drag tiles to reorder them or
move them into Pinned or Today. Links dragged from a webpage or another app can be
dropped onto the grid or address pill to save a favourite; dragging a tile into another
app exports its page link.

## Spaces

Create a Space from **Spaces → New Space…** or the sidebar creation menu. Choose a name,
profile, and appearance. Right-click its name or footer button to edit its theme.

Hover the Space card to reveal its chevron and `…` menu. Click the card to collapse or
expand its pinned tabs; Today stays visible. Double-click its name to rename the Space.
Each window remembers the collapsed state for each Space while open. Swipe horizontally
over the sidebar to move between Spaces, including while the search bar (`⌘T`) is open.
Click the Space buttons in the sidebar footer for the same sliding change, including
between profiles. Each button shows a rounded highlight on hover. Reduce Motion and
Battery Saver keep click changes immediate.

For saved workspace layouts, see [Space templates](FEATURES.md#space-templates). To
restrict access to a folder, see [folder locks](DATA-AND-PRIVACY.md#folder-locks).

## Windows, Split View, Peek, and Little Vane

Use **File → New Window** (`⌘N`) for a regular window, **New Private Window**
(`⇧⌘N`) for private browsing, or **New Little Vane Window** (`⌥⌘N`) for a compact
single-page window. These are the default bindings; Settings can change them.

Windows in the same Space share tabs. When both show the same tab, the focused window
holds its live page and the other shows a gray snapshot. Switching windows preserves
input, scroll position, and history; closing a tab removes it from every window. Each
window keeps its own selection. Private and Little Vane windows keep their own pages.
Split View shows two to four pages side by side or stacked, with resizable dividers.
Peek opens a link over the current page; Little Vane opens it in a separate compact
window.

## Search and history

Type a site word such as `youtube`, `github`, or `twitter` in the search bar and press
**Tab** (or click **Search …**) to turn it into a site search chip. Shortcut keywords
such as `yt` and your custom bangs work too. Typing `!yt ` activates the chip directly.
The selected result uses the site's chip color; **Return** searches that site, and an
empty query opens its home page. **Escape**, clicking the chip, or **Backspace** with an
empty query leaves site search. Words remain ordinary searches until activated. Tab
still searches actions when no site shortcut matches. Built-in sites also include
Twitch, TikTok, Pinterest, Bluesky, IMDb, SoundCloud, Vimeo, Letterboxd, Goodreads,
Medium, Etsy, Target, Dribbble, Behance, Unsplash, Pexels, GitLab, and DEV.to. Full site
names work with `!` too, such as `!youtube` and `!github`; `twitter` and `!twitter`
search X. Some sites require sign-in.

### Tab and history results

Search ranks exact page titles and addresses before prefixes, partial words, and fuzzy
letter matches. Accents and case do not affect matching. Bookmarks, visit frequency, and
recency break relevance ties. Tab search searches the current profile and offers an
**All open Spaces** filter for the live tabs it can access. History (`⌘Y`) offers
explicit profile selection and Today, Yesterday, Last 7 days, and Last 30 days filters.
Search results show relevance first and include each visit's date; an empty search
groups visits by day. History has no Space filter because visits do not store which
Space they belonged to. Private windows show neither saved history nor other windows'
tabs. Searches run off the input thread and discard superseded results.

## Library and downloads

Hover the Library bucket in the sidebar footer to preview the last four downloads, with
the newest at the bottom. Thumbnails, filenames, and relative times appear over the
lower Today tabs; click a finished file to open it or right-click to show it in Finder.
**Settings → General → Previews → Library hover preview** selects Downloads (the
default), Media, Easels, Spaces, Archived Tabs, History, or Off. Each preview shows up
to four items. Downloads and Media are shared across all regular profiles and windows;
the other previews use this window's profile. Private windows show only their own
downloads, media, and archived tabs. The bucket is empty when downloads, archived tabs,
and the selected preview are empty, and always highlights on hover. A filled bucket
lifts its contents without changing their shape; an empty one lifts its lid. Reduce
Motion and Battery Saver keep these changes immediate. Click the bucket to open the full
Library.

Starting a download sends a small marker from the page into the Library bucket. The
bucket briefly shows the file type's icon on arrival. Reduce Motion and Battery Saver
show the icon immediately without the flight.

Swipe right to left within the Library panel to close it, or use Escape or its back
button. From the leftmost Space, swipe left to right over the sidebar to open Library at
its last-used section. Swipes over page content stay with the page, including back and
forward navigation. Vertical scrolling still scrolls the Library.

Downloads can be paused, resumed, or retried when supported. Resume depends on the
server, WebKit resume data, authentication, and destination access. Fresh Retry requires
a recorded GET; POST exports and blob/data downloads need the source page again. See
[download reliability](DOWNLOAD-RELIABILITY.md) for behavior, troubleshooting, and
byte-level validation.

## Picture in Picture and media

Picture in Picture uses a custom floating window that you can drag anywhere and resize,
with Back to Tab, minimize, close, play/pause, 15-second skips, and a seek bar. Hold the
seek knob and drag upward for finer horizontal seeking; the center shows the current
precision (2×, 4×, 8× and up) while you scrub. The corners have larger resize targets
that preserve the video's proportions and opposite corner. It remembers its last
position and size when reopened. Entry moves the live video from its on-page position to
the saved placement in one short motion. Back to Tab reveals the source tab and moves
the live video back to its current on-page position. Reduce Motion keeps these
transitions in place. Minimize hides it while playback continues. The sidebar video
player appears after minimizing PiP. It stays available across this window's Spaces,
including Spaces in other profiles. Returning to its source Space keeps the minimized
player visible until you open its tab, restore Picture in Picture, or close the player.
It keeps the site icon and transport controls visible; hover over it to see the title,
restore Picture in Picture, or close the player and pause. Embedded players use their
own frame and Media Session play/pause and skip handlers. The custom window keeps
WebKit's original live video presentation, including embedded players; when its
presentation view cannot be safely attached, Vane keeps the native Picture in Picture
window as a fallback.

Protected playback depends on the system WebKit engine and the service. Public FairPlay
demo checks do not establish subscription-service compatibility; see the [compatibility
evidence](REAL-SITE-COMPATIBILITY.md).

## Shortcuts and keyboard navigation

| Action | Default shortcut |
| --- | --- |
| New tab | `⌘T` |
| Reopen closed tab | `⇧⌘T` |
| Find on page | `⌘F` |
| Move between page and browser controls | `F6` or `⇧F6` |
| Search tabs | `⇧⌘A` |
| Search commands | `⇧⌘P` |
| Open Library | `⇧⌘L` |

Shortcuts can be changed in Settings. The menu bar shows the current bindings, including
numbered tab selection and search commands. Choose **Prefer Website** for a shortcut to
leave it with a focused webpage; the command remains available from the menu and while
browser controls have focus. Option-only shortcuts also leave character entry and caret
movement with a focused text editor.

Use **F6** (or **Shift-F6**) to move between the page and browser controls, revealing
the sidebar if needed. Use **Tab** and **Shift-Tab** to move through browser controls.
Sidebar tabs, favourites, folders, Spaces, split panes, and the address pill show a
focus outline; **Return** or **Space** activates the focused control. Enable macOS
**Keyboard navigation** to include native buttons and menus in Tab navigation. Search
results use **Up/Down** and **Return**; **Tab** keeps its site-search and actions
behavior. **Escape** dismisses search or Find and returns focus to the page when no
other control has taken it. **⌘F** refocuses an already-open Find field. VoiceOver can
activate sidebar items directly and use their Actions menu for secondary commands.

### Link gestures

While hovering a webpage link, hold a modifier to see where clicking will open it:

| Link gesture | Result |
| --- | --- |
| `⌘`-click or middle-click | New background tab |
| `⇧⌘`-click | New tab, focused immediately |
| `⌥`-click (also `⌥⇧`) | Split View beside the source page, up to four panes |
| `⌥⌘`-click (also `⌥⇧⌘`) | Little Vane |
| `⇧`-click | Peek, including from pinned and favorite tabs |

Settings › Links can disable the Little Vane and Shift-click Peek gestures. With Little
Vane disabled, `⌥⌘` follows the normal Command-click tab behavior. The automatic Peek
preference for links leaving pinned sites is independent. Shift-hover previews still
require Previews to be enabled; holding Command or Option hides the preview so it does
not cover the opening hint. Floating windows keep their existing one-page behavior and
do not grow Split Views.

## Unfinished work and recovery

Unfinished form work stays in the live page across tab, Space and shared-window
switches. Automatic suspension, Battery Saver and memory pressure defer unloading
pages with detected drafts or uncertain detection. Draft contents are not saved to
disk and cannot be recovered reliably after a process crash. See
[unfinished work and suspension](DRAFT-PROTECTION.md) for coverage and limits.

After an unclean exit or a webpage-process termination, affected pages stay paused with
an **Open Page** action. Recovery opens a fresh URL without replaying a saved form
submission. Session files retain a validated previous generation and preserve damaged
originals before replacement. See [crash and session recovery](CRASH-RECOVERY.md) for
saved-state boundaries, storage failures, and the isolated macOS checks.

Navigation and form-resubmission fixes have [local WebKit
evidence](NAVIGATION-RELIABILITY.md). These fixtures do not establish every remote-site
or network failure scenario.
