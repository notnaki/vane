# Everyday browsing

[Documentation index](README.md) · [Project README](../README.md)

Tabs, Spaces, windows, search, downloads, and media. For Reader, translation, Easels,
captures, Boosts, and appearance, see [Reading and customization](FEATURES.md).

## First launch

A new installation opens with a short welcome to search and Spaces. Skip it at any time.
Release builds offer once to make Vane your default browser; you can also do this later
in **Settings → General → Default browser**.

## The sidebar

- **Favourites** belong to a profile and appear in every Space of that profile.
- **Pinned** and **Today** tabs belong to a Space. Today tabs can archive themselves;
  find them in **Library → Archived Tabs**. Right-click a row to pin or unpin it.

Press <kbd>⌘S</kbd> (**Toggle Sidebar**) to show or hide the sidebar. Each window
remembers its own choice across all its Spaces. Hiding it also closes Library. In full
screen, the sidebar button moves to the top-left corner.

Move the pointer over the sidebar to reveal the address pill's pinned extensions,
**Copy Link**, and **Site Controls**, and Today's **Clear** button. Hover a tab to see its
close button.

Double-click a tab, favourite, or split pane to rename it. <kbd>Return</kbd> saves,
<kbd>Esc</kbd> cancels, and an empty name restores the page title.

A pinned tab keeps its name as you browse inside it. Once it leaves its saved page, the
row shows `/` before the title; choose **Back to Pinned URL** to go back.

## The toolbar

**View → Show Toolbar** (<kbd>⇧⌘D</kbd>) adds a slim strip to the top of the page with
Back, Forward, Reload, the page's address, **Copy Link**, pinned extensions, and Page
Actions. Click the address to edit it. In Split View each pane gets its own strip. With
the sidebar hidden, the strip also holds the window buttons and the sidebar button, and
you can drag it to move the window. The setting applies to every window.

Little Vane and Peek keep their own bar. To hide it until you point at the top edge, turn
on **Settings → Links → Auto-hide toolbar in Little Vane and Peek**.

## Site Controls

Click the Site Controls button in the address pill for quick actions on the current site:
**Share**, **Boost**, **Capture**, and **Reader**, plus a tile for each installed
extension (click a dimmed tile to turn it on). Below, a short **Settings** list shows only
what this site has changed: permissions you answered, zoom, ad blocking, translation,
apps it may open, and Developer Mode. Click a row to flip it.

**⋯ → Site Settings…** lists every permission and site option. The **⋯** menu also has
**Clear Site Data…**, **Translate Page**, extension management, and filter lists. Right-
click an extension for its options, **Pin**/**Unpin**, or **Remove from Vane…**. See
[site permissions](SITE-PERMISSIONS.md).

**Act as Chrome** (in **⋯** and **Site Settings…**) is for sites that turn away browsers
other than Chrome. It is off by default and works per site and per profile. In private
windows it is kept in memory until Vane quits, shared by all private windows. When on,
that site sees a Chrome user agent and Chrome's `navigator` details. Other sites keep the
normal identity. Turning it on reloads the page. Streaming video (Netflix, Disney+) may
stop working with it on. If you picked a user agent in **Develop → User Agent**, that
choice applies everywhere and this switch is unavailable.

It matches the exact host (`www.example.com` and `example.com` are separate). If a site
sends other browsers to an "unsupported browser" page on another host, go back to the
site's own address and turn it on there, not on the warning page. Only the page itself
gets Chrome's `navigator`: extension content scripts and Web Workers see a Chrome user
agent but Apple's `navigator.vendor` and no `userAgentData`. A form that posts and then
redirects onto or off a switched site keeps the first request's user agent for that one
redirect.

## Copy a clean link

<kbd>⇧⌘C</kbd> (**View → Copy Page URL**) or **Copy Link** copies the address with
tracking parameters such as `utm_*` and `fbclid` removed. Search terms, item IDs, and
fragments stay.

## Organise tabs

**Reorder.** Drag a tab; a white line shows where it will land. Hold <kbd>⌥</kbd> while
dropping onto another tab to make a Split View. Drop onto a closed folder to put it
inside.

**Folders.** Rest the pointer on a collapsed folder to see its tabs in a panel, each with
when you last visited it. Type in **Search *folder*…** to filter, press <kbd>Return</kbd>
to open the first match, or click a row. Locked folders don't preview. To move tabs out of
a folder, drag them into the empty space below the last row, onto **New Tab** (top of
Today), or choose **Remove from Folder**. Empty folders disappear. Drag the empty space
below Today to move the window.

**Favourites.** Drag a tab, or a link from a page or another app, onto the Favourites
grid or the address pill. Neighbouring tiles move aside to show where it will go. Drag
tiles to reorder them, back into Pinned or Today, or into another app to share the link.

**Tidy Tabs** (<kbd>⌃⌘T</kbd>) proposes folders for your Today tabs. Rename folders or
untick pages, then choose **Apply Groups**. Pinned tabs, favourites, existing folders,
split panes, and custom names are never moved. **Undo Tidy Tabs** reverts it. To skip the
review, turn off **Settings → Max → Preview before tidying**.

**Organize Tabs** (**Tabs → Organize Tabs…** or the Space menu) searches Today tabs across
the profile's Spaces. Copy their links, move them to another Space, or archive them. Turn
on **Duplicates only** and **Select Extras** to clean up copies; Vane keeps at least one
and prefers pinned, favourite, named, and in-use tabs. Pinned tabs, favourites, split
panes, and locked folders are protected. **Tabs → Undo Tab Organization** reverts the last
action.

## Spaces

Create a Space from **Spaces → New Space…** or the sidebar's creation menu, then choose a
name, profile, and appearance. Right-click the Space to edit its theme or choose an
**Icon** or **Emoji**.

**Switch Spaces** by swiping horizontally over the sidebar, clicking a footer button, or
pressing <kbd>⌃1</kbd>–<kbd>⌃9</kbd> or <kbd>⌥⌘←</kbd>/<kbd>⌥⌘→</kbd>. Pull past the last
Space until the ring fills to start a new one. To show dots instead of icons in the
footer, turn off **Settings → General → Space icons in the footer**.

Click the Space card at the top of the sidebar to collapse its pinned tabs; double-click
its name to rename it.

**Manage Spaces** (**Spaces → Manage Spaces…**) shows every Space across profiles. Click a
card to go to it. Drag cards, or the footer buttons, to reorder. Spaces share one order
across all profiles, kept in backups and synced over iCloud when **Spaces** and **Sidebar
folders** sync are on. Reordering never changes a Space's profile. A card's **⋯** menu
renames it or deletes it; **Delete Space…** asks first and archives its tabs.

See also [Space templates](FEATURES.md#space-templates) and
[folder locks](DATA-AND-PRIVACY.md#folder-locks).

## Windows

| Window | Shortcut |
| --- | --- |
| **File → New Window** | <kbd>⌘N</kbd> |
| **File → New Private Window** | <kbd>⇧⌘N</kbd> |
| **File → New Little Vane Window** (one compact page) | <kbd>⌥⌘N</kbd> |

Right-click the Dock icon for **New Window**, **New Incognito Window**, **Show Little Vane
Windows**, and **Close Little Vane Windows**.

Window titles follow the active page (`Page title — Vane`), which helps password managers
and window tools. Turn this off in **Settings → Advanced → Windows and Tabs → Show page
titles in window titles**. Private windows always use generic titles.

Windows on the same Space share its tabs but keep their own selection. If two windows show
the same tab, the focused one has the live page and the other shows a snapshot. Private
and Little Vane windows keep their own pages.

Website sign-in pop-ups open in a small temporary window showing the site's address.
`alert()`, `confirm()`, and `prompt()` appear as sheets naming the site; a site that keeps
repeating them can be silenced until the tab closes.

## Split View, Peek, and Little Vane

- **Split View** shows two to four pages side by side or stacked, with dividers you can
  drag. <kbd>⌥</kbd>-click a link, or press <kbd>⌃⇧=</kbd>.
- **Peek** opens a link over the current page. <kbd>⇧</kbd>-click a link.
- **Little Vane** opens a link in a compact separate window. <kbd>⌥⌘</kbd>-click a link.

See [link gestures](#link-gestures) for every modifier.

## Search and history

Press <kbd>⌘T</kbd> or <kbd>⌘L</kbd> to open the search bar. Results grow below the field
as you type.

- **Autocomplete.** Typing the start of a site you've visited completes it. Press
  <kbd>→</kbd> to accept and keep editing, or <kbd>Delete</kbd> to remove it.
- **Site search.** Type a site name such as `youtube` or `github` and press
  <kbd>Tab</kbd> to search that site. Keywords like `yt`, bangs like `!yt` or `!github`,
  and your custom bangs work too. Built-in sites include Twitch, TikTok, Pinterest,
  Bluesky, IMDb, SoundCloud, Vimeo, Letterboxd, Goodreads, Medium, Etsy, Target, Dribbble,
  Behance, Unsplash, Pexels, GitLab, DEV.to, and X (`twitter`).
- **Actions.** Commands such as **Pin Tab** appear when you type their name. Press
  <kbd>Tab</kbd> (or click **⇥ Actions**) to search only actions.
- **Instant Links.** <kbd>⇧Return</kbd> opens DuckDuckGo's first result directly, whatever
  your search engine. Separate queries with commas to open several tabs. Turn it off in
  **Settings → Max → Instant Links**. Not used in private windows. See the
  [privacy policy](../PRIVACY.md).
- **Tabs and history.** <kbd>⇧⌘A</kbd> searches open tabs, with an **All open Spaces**
  filter. <kbd>⌘Y</kbd> opens History, filtered by profile and by Today, Yesterday,
  Last 7 days, or Last 30 days.

Set the number of results, bar position, and animation in **Settings → Advanced → Command
Bar**. Search engines open from **Settings → Profiles → Search Settings…**.

## Settings pages in a tab

Passwords, Privacy and Security, Website Data, Clear Browsing Data, Search Engines, and
Extensions open as a browser tab, like in Arc. Reach them from the arrow rows in
**Settings → Profiles**, **Manage Extensions**, or by typing `vane://` in the command bar.
Each page has a profile menu, so you can manage any profile, even one no Space uses.
Typing `settings` still opens the Settings window.

## Library and downloads

Press <kbd>⇧⌘L</kbd> or click the bucket in the sidebar footer to open Library. It holds
Downloads, Media, Easels, Boosts, Archived Tabs, and Reading Queue for every profile. You
can also swipe past your first Space to reach it.

Hover the bucket to preview the last four downloads. Click one to open it, or right-click
to show it in Finder. Choose what the preview shows in **Settings → General → Previews →
Library hover preview**. New downloads fly into the bucket.

In Downloads, Archived Tabs, and Reading Queue, **Filter** narrows the list by profile.
Its **⋯** menu has more filters and actions such as **Clear Downloads**.

**Reopen Closed Tab** (<kbd>⇧⌘T</kbd>) brings back any of the last 32 closed tabs until
you quit, with their Back/Forward history.

Downloads can be paused, resumed, or retried where the server allows. See
[download reliability](DOWNLOAD-RELIABILITY.md).

## Picture in Picture and media

Press <kbd>⌥⌘P</kbd> to pop a video out. The floating player can be moved and resized and
has play/pause, 15-second skips, a seek bar, and **Back to Tab**. Drag the seek knob
upward for finer scrubbing. Minimise it to keep listening from a small player in the
sidebar.

Leaving a tab with a playing video pops it out automatically. Muted videos, such as
decorative background loops, are skipped. Turn this off in **Settings → Advanced → Media
and Notifications → Automatically enter Picture in Picture**.

**Pause All Media** (**View** menu or command bar) pauses everything playing in every
window, Space, and profile, without switching tabs or waking sleeping ones. It never
resumes anything and leaves calls alone. Assign it a key in **Settings → Shortcuts**.

**Google Meet** calls float in their own window when you leave the tab (when automatic Picture in Picture is on), with Meet's own
controls. **Close** hides the window without leaving the call. The sidebar shows a camera
and a red dot while you're in a call.

Protected streaming (Netflix, Spotify, Disney+) depends on the service; see
[streaming compatibility](STREAMING-COMPATIBILITY.md).

## Offline

Without a connection you can still organise tabs and Spaces, browse bookmarks and
history, edit Easels, open downloads, and read articles saved in **Library → Reading
Queue** (see [offline reading](FEATURES.md#offline-reading-queue)). When a page says
you're offline, reconnect and choose **Try Again**.

## Updates

Choose **Vane → Check for Updates…**. If a check or download fails, choose **Retry**. A
downloaded update installs when you choose **Restart** in the update pill, which appears in
every Space.

## Shortcuts and keyboard navigation

| Action | Shortcut |
| --- | --- |
| New tab / search | <kbd>⌘T</kbd> |
| Reopen closed tab | <kbd>⇧⌘T</kbd> |
| Find on page | <kbd>⌘F</kbd> |
| Search tabs | <kbd>⇧⌘A</kbd> |
| Search commands | <kbd>⇧⌘P</kbd> |
| History | <kbd>⌘Y</kbd> |
| Library | <kbd>⇧⌘L</kbd> |
| Toggle sidebar | <kbd>⌘S</kbd> |
| Show toolbar | <kbd>⇧⌘D</kbd> |
| Copy clean link | <kbd>⇧⌘C</kbd> |
| Capture part of the page | <kbd>⇧⌘2</kbd> |
| Picture in Picture | <kbd>⌥⌘P</kbd> |
| Move between page and browser | <kbd>F6</kbd> / <kbd>⇧F6</kbd> |

Change any shortcut in **Settings → Shortcuts**. Choose **Prefer Website** to let a
focused page keep a key.

<kbd>Tab</kbd> and <kbd>⇧Tab</kbd> move through browser controls; <kbd>Return</kbd> or
<kbd>Space</kbd> activates them. <kbd>Esc</kbd> closes search or Find and returns to the
page. VoiceOver can use each sidebar item's Actions menu.

### Link gestures

Hold a modifier over a link to see where it will open.

| Gesture | Opens in |
| --- | --- |
| <kbd>⌘</kbd>-click or middle-click | New background tab |
| <kbd>⇧⌘</kbd>-click | New tab, focused |
| <kbd>⌥</kbd>-click | Split View, up to four panes |
| <kbd>⌥⌘</kbd>-click | Little Vane |
| <kbd>⇧</kbd>-click | Peek |

Turn off the Little Vane and Peek gestures in **Settings → Links**.

## Unfinished work and recovery

Pages with unsaved form input are not put to sleep, so drafts survive switching tabs and
Spaces. To keep specific sites always loaded, add them in **Settings → Advanced →
Performance → Keep these sites loaded** (optionally with subdomains). This applies to
every profile.

After a restart, tabs load when you open them. If a page crashes, choose **Open Page** to
reload it.

## Limits

- Drafts live only in the open page and are lost if Vane crashes. See
  [unfinished work](DRAFT-PROTECTION.md) and [crash recovery](CRASH-RECOVERY.md).
- History has no Space filter; private windows show no history and no other windows' tabs.
- Restored tabs and bookmarks are not offline copies. New pages, searches, streaming,
  downloads, cloud AI, and extension or filter updates need a connection.
- Resuming a download depends on the server; some exports need the source page again.
- Pause All Media can't pause Web Audio that has no media element.
- Meet detection depends on Google's page and may need updates when it changes.
- Protected video quality depends on the service. See
  [streaming](STREAMING-COMPATIBILITY.md) and
  [real-site compatibility](REAL-SITE-COMPATIBILITY.md).
