# Reading and customization

[Documentation index](README.md) · [Project README](../README.md)

Use these tools to read, collect, and adapt pages. [Browsing](BROWSING.md) covers
everyday navigation; [integrations](INTEGRATIONS.md) covers blocking, extensions, and
AI.

## Reader

Enter Reader from Page Actions or **View → Reader Mode**. **Page Actions → Reading
Preferences** offers text size (13–32 pt), serif type, compact/standard/relaxed line
spacing, and narrow/standard/wide reading columns. Spacing and width are also in **View
→ Reading Preferences**. Preferences save locally and apply immediately to the current
Reader; new Reader views use the saved choices. These preferences are shared across
profiles and private Reader views and included in complete backups. Changes animate
briefly unless Reduce Motion or Battery Saver is active. The header links to the source
article, and article links remain usable.

Extraction retains scored sibling sections, prose in legacy table layouts, technical
data tables, code indentation, and lazy image captions while omitting hidden content and
navigation. It remains heuristic: unavailable/paywalled text, embedded frames, and
articles below the 140-word threshold are not recovered. Exit Reader reloads the
original page; it does not add a history entry.

## Offline reading queue

Choose **Page Actions → Save for Offline** or **View → Save for Offline** on a readable
article. **Library → Reading Queue** holds all profiles' saved copies, searches their
article text as well as titles and links, and offers All, Unread, and Read filters. Open
a saved copy without a connection, explicitly mark it read or unread, or remove it to
reclaim storage. The queue shows its article count and storage usage. Opening does not
automatically mark an article read. Saving an already saved URL keeps the existing copy;
remove it and save again to capture a newer version.

Saved Reader labels the **Saved copy**, capture date, and source, reuses Reader's
reading preferences, and offers **Open Live Page** separately. Saves publish atomically
in local profile storage and participate in complete backups and restore. Private
browsing cannot persist or access the queue. Unsupported pages and failed saves explain
the problem. Images are captured where practical through anonymous requests;
authentication, size limits, or failed downloads can leave a text-only copy with a
missing-image notice. Saved views never fetch missing images from the live site. The
queue focuses on article text rather than interactive pages or PDFs; it supports up to
1,000 articles per profile and 20 MiB per article. Backup exports retain their 512 MiB
total limit and report a failure without omitting saved content.

## Easels

Easels open as native tabs inside the browser. Choose **New Easel** from the sidebar's
**+** menu, type **New Easel** in the command palette (`⌘T`), or use **File → New
Easel** (`⌥⌘E`). New boards are pinned in the current Space and return after relaunch.
Find all saved boards under **Library → Easels** or **Window → Show Easels**; opening a
board already in this Space focuses its existing tab. Closing or unpinning a tab keeps
its board in Library. **File → Capture Page to Easel** (`⇧⌘E`) collects the visible
webpage into the most recently used Easel in this Space, or the latest saved board, with
its source link. Boards belong to the browser window's profile and save locally after
each edit. Private windows cannot create boards or save captures. To move a Space to
another profile, remove its Easel tabs first; their boards stay owned by the original
profile and visible in the shared Library. Export/import a board to copy it to another
profile.

### Tools and annotations

The centered toolbar follows Excalidraw's tool order: selection, rectangle, diamond,
ellipse, arrow, line, drawing, text, and image. Click an object once to select it; drag
anywhere inside its box to move it, including the empty interior of an outlined shape.
All four corner handles resize. Double-click text to edit it inline, or a rectangle,
diamond, or ellipse to add its label. With the Text tool, drag out the text box before
typing, or click for a default size. Colors, shape fills, stroke widths, and text sizes
live in the left panel. Text supports Excalidraw's bundled Excalifont, normal and code
faces, and left/center/right alignment. Shapes offer sharp/rounded edges,
solid/dashed/dotted strokes, solid/hachure/crosshatch fills, three sloppiness levels,
and opacity. The hand tool pans the canvas; the lock keeps a drawing tool active. Tool
shortcuts are shown in the toolbar. Arrow keys nudge a selected item (Shift moves ten
points), Enter edits its text, and ⌘D duplicates it. Notes, links, and clipboard paste
are in the **…** menu. New captures are selected when their board opens. Click an
image's pencil, **Annotate Image** in its context menu, or the selected image's
properties to pause its live source and activate the existing drawing tool with the tool
lock on. Draw on the saved capture, or choose arrows, shapes, and text in the same
toolbar. Choose Select or press Escape to move items afterwards. Double-click an image
to edit its caption or crop it. Undo/redo and zoom controls sit at the bottom left.
Choose Select to move items after drawing. Scroll in either direction and choose a zoom
level. New items appear near the current canvas viewport. Standard Undo/Redo work on the
board and inside its text editors. Annotations remain independent editable objects;
moving or cropping an image does not transform its annotations with it. Image import
preserves the available pixel resolution while keeping the canvas card compact; images
beyond 8 MiB PNG, 16,000 pixels on either side, or 32 million pixels are refused rather
than silently downsampled. Board PNG export still uses the 4,096-pixel limit below.

### Live web captures

A web capture's play button opens its source page as an interactive live view using that
profile's cookies and content blocker. Pause returns to the saved image. Live views are
temporary, limited to four at once, and stop when switching boards or leaving the Easel
tab or closing the window. They show the source page rather than a live cropped region;
permission prompts, popups, password autofill, and downloads belong in browser tabs.

### Library, export, and limits

The `…` menu duplicates or deletes a board, exports a PNG, or exports an editable JSON
document with embedded images. **Library → Easels** shows a searchable card grid; each
card’s **… → Delete Easel…** removes the local board after confirmation. Import JSON
from the Library’s bottom **…** menu. The canvas is 6,000 × 4,000 points; a board holds
up to 256 items, and PNG export scales the entire occupied canvas to at most 4,096
pixels. Easels do not include cloud sharing or collaboration.

## Page capture

Capture part of a page with **⌘⇧2**, **File → Capture a Portion of This Page**, the
camera row in Site Controls, or by searching for **Capture** in the command palette.
Click a highlighted element or drag a rectangle over the visible page; **Escape**
cancels. **Return** captures the highlighted region or the visible page. The preview
offers **Copy**, **Save PNG**, **Share**, and **Add to Easel**. In an ordinary browser
window, **Add to Easel** saves the region with its source link to a new or existing
board and opens that board's tab. Captures use WebKit's page pixels at the display's
resolution and need no screen-recording permission. An embedded frame is selected as a
whole; custom drags can crop inside it. Captures are saved only when you choose an
output action, including in private windows.

## Site Boosts

Choose **Site Controls → Boost This Site** to customize a website while viewing it. The
native Boost editor previews fonts, text size, background/text/link colors, and custom
CSS as you edit (CSS `@import` is not supported). **Zap an Element** highlights what is
under the pointer; click to hide it, select **Undo** or a saved selector's restore
button to bring it back, and press **Escape** to finish. Hidden-element rules also apply
to content added later. A site's markup changes can require selecting an element again;
iframes can be hidden as a whole, and shadow-root contents are not edited.

Boosts save locally per profile and exact website origin (scheme, host, and port).
Subdomains have separate Boosts. Private tabs keep their own temporary changes.
**Library → Boosts** lists all profiles' saved Boosts, including disabled ones.
Search by site address or profile, open a site, or use a row's menu to enable, disable,
or delete its Boost. The section is hidden in private windows.

**Code → JavaScript** offers an explicit **Enable JavaScript** switch and **Apply Script**
button. Enabled scripts run once after each new document loads; editing code alone does
not run it. Script errors appear in the editor. Disabling or resetting prevents future
runs; reload the page to remove effects already made by a script. **Reset Boost**
restores the site's visual defaults, and **Settings → Profiles → Site Permissions →
Reset Boosts…** removes all Boosts in that profile. Reduce Motion and Battery Saver keep
editor transitions immediate.

## Space templates

Choose the Space menu → **Save Space as Template…** to save a named workspace. **Space
Templates…**, also available as **New Space from Template…** in the creation menu,
previews the current profile’s saved setups and creates a new Space. Templates preserve
pinned and Today tab order, duplicate pages, custom names, nested folders, Space
appearance, and supported split layouts including divider sizes. Rename a template,
update it from the current Space after reviewing its contents, or delete it; already
created Spaces keep their own contents.

Locked-folder contents require macOS authentication before saving, previewing, or
recreating them. New folders retain their locks and receive fresh identities. Templates
save addresses and layout without cookies, credentials, website storage, or WebKit
navigation state; pages can still use their profile’s existing sign-ins. Credential-like
URL parameters and URL userinfo are removed. Blank tabs, files, and local Easel
documents are excluded and counted in the preview. Live folders become ordinary folder
snapshots, and Favourites remain shared by the profile. Private and Little Vane windows
cannot save templates. A failed save leaves the previous version safe, and a failed
creation leaves no partial Space. Template files use the same atomic persistence and
profile filename conventions as Spaces for backup/restore.

## Appearance and icons

Space themes control colors, gradients, grain, and light/dark appearance. Open the theme
editor from a Space’s context menu. Keyboard bindings and website priority are in
[shortcut settings](BROWSING.md#shortcuts-and-keyboard-navigation).

Settings → Icon offers Normal, Dark, Galaxy, Candy, Neon, Fluted Glass, Fluted Glass
Dark, Schoolbook, and Luminous. The choice persists across launches and changes the
running app's Dock and Finder icons, including while Vane is quit. Minimized-window
previews also use the selected icon and update when the choice changes. A signed helper
stamps the containing app bundle outside the browser sandbox; read-only or translocated
copies retain the live Dock choice and restore it on launch. The bare SwiftPM executable
has no bundled icon catalogue; build `Vane.app` to use these finishes.

Icon asset maintenance is documented in [AppIcons](../AppIcons/README.md).

## Battery Saver and motion

Battery Saver lives in **Settings → Advanced → Performance**. Choose **Off**,
**Automatic** (below 20% battery while unplugged), or **Always On**. While active,
eligible idle tabs sleep after five minutes, hover link previews pause, and sidebar
motion is reduced. Active pages, pinned tabs, media/Picture in Picture, private tabs,
and unfinished forms keep their existing suspension protections. State changes show a
temporary green lightning popup at the page's top right, with an **Edit this setting**
button. Hovering keeps the popup visible; sleeping tabs reload when selected. The mode
respects the existing idle-suspension preference and preserves an already shorter
timeout.

UI transitions respect system Reduce Motion and Battery Saver. [Responsiveness
evidence](UI-RESPONSIVENESS.md) records measured improvements and unproven frame/latency
targets. [Lifecycle evidence](LIFECYCLE-EFFICIENCY.md) records ownership fixes and the
limits of local resource measurements.
