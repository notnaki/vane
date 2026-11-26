# Reading and customization

[Documentation index](README.md) · [Project README](../README.md)

Read, collect, and reshape pages. [Browsing](BROWSING.md) covers everyday navigation;
[integrations](INTEGRATIONS.md) covers extensions, blocking, and AI.

## Reader

Choose **View → Show Reader** (<kbd>⌥⌘R</kbd>) or Reader in Page Actions or Site Controls
to read an article without clutter. **Page Actions → Reading Preferences** sets text size,
serif type, line spacing, and column width. Your choices apply to every Reader view.
Exiting Reader reloads the original page.

## Translate Page

Choose **View → Translate Page**, or Translate in Page Actions, Site Controls, or the
command bar, to translate the page in place into your preferred macOS language.
Translation runs on your Mac with Apple's Translation; page text never leaves it. If a
language isn't downloaded yet, macOS asks first. Form fields and code are left alone.
Choose **Show Original** to undo.

When a page loads in another language, Vane offers **Translate this page?** under the
address bar: **Translate**, **Not now**, or **Never Translate This Site**. After you
translate, later pages on that site in the same tab translate automatically. To be
offered again on a site, turn on **Offer to Translate** in Site Controls.

## Ask on Page

Ask a question about the page you're reading. Press <kbd>⌘F</kbd> and click the sparkles
button, or choose **Ask on Page** in the command bar. Ask follow-ups in the same field.
It uses Apple's on-device model by default; see
[Ask on Page](INTEGRATIONS.md#ask-on-page) for routes and privacy.

## Offline reading queue

Choose **Save for Offline** in Page Actions or the **View** menu to keep an article.
**Library → Reading Queue** holds saved copies from every profile. Search titles, links,
and article text, filter by **All**, **Unread**, or **Read**, and mark or remove items.
The queue shows how much storage it uses.

A saved copy opens in Reader with its capture date and an **Open Live Page** button.
Saving the same address again keeps the first copy; remove it and save again to refresh.

## Easels

Easels are freeform boards for notes, drawings, and captures. Create one with **File →
New Easel** (<kbd>⌥⌘E</kbd>), the sidebar's **+** menu, or the command bar. New boards are
pinned in the current Space. Find every board in **Library → Easels** or **Window → Show
Easels**. Closing a tab keeps its board.

**File → Capture Page to Easel** (<kbd>⇧⌘E</kbd>) adds the visible page, with its link, to
your most recent Easel.

### Tools and annotations

The toolbar has selection, rectangle, diamond, ellipse, arrow, line, drawing, text, and
image tools, in Excalidraw's order. The left panel sets colour, fill, stroke, sloppiness,
opacity, font, and alignment. The hand tool pans; the lock keeps a tool active.

- Drag to move, use the corner handles to resize, and double-click text or a shape to
  edit its label.
- Arrow keys nudge (<kbd>⇧</kbd> for ten points), <kbd>Return</kbd> edits text, and
  <kbd>⌘D</kbd> duplicates.
- Click an image's pencil, or choose **Annotate Image**, to draw on it. Double-click an
  image to edit its caption or crop it.
- Notes, links, and paste are in the **⋯** menu. Undo, redo, and zoom sit at the bottom
  left.

### Live web captures

Click a web capture's play button to turn it into a live, interactive view of the page.
Pause returns to the saved image. Up to four live views run at a time, and they stop when
you leave the board.

### Library, export, and limits

A board's **⋯** menu duplicates or deletes it and exports a PNG or an editable JSON file.
Import JSON from the bottom **⋯** menu in **Library → Easels**.

A board is 6,000 × 4,000 points and holds up to 256 items. PNG exports are at most 4,096
pixels on the long side. Easels are local; there is no sharing or collaboration.

## Page capture

Press <kbd>⇧⌘2</kbd>, choose **File → Capture a Portion of This Page**, or click Capture in
Site Controls. Click a highlighted element or drag a rectangle; <kbd>Return</kbd> captures
the visible page and <kbd>Esc</kbd> cancels. Choose **Full Page** (or **File → Capture
Full Page**) to include everything below the fold.

The menu beside the capture offers **Copy**, **Save PNG…**, **Share…**, **Edit…**,
**Retake**, **Save to Library**, and sending to a new or existing Easel. **Edit** adds
crop, pen, arrows, rectangles, and text. Saved captures appear in **Library → Media**. No
screen-recording permission is needed.

## Site Boosts

Click **Boost** in Site Controls to restyle a site. The Boost panel floats over the page
(drag it to move) and previews as you go:

- **Colours.** A colour pad with light/dark, contrast, brightness, and saturation.
- **Type.** A font grid, **Size**, and **Case**.
- **Zap.** Click an element, then choose **Zap this** or **Zap all related elements** to
  hide it. <kbd>⌘Z</kbd> undoes; <kbd>Esc</kbd> finishes.
- **Code.** Custom CSS, and JavaScript that runs on each page load once you turn on **Run
  JavaScript**.

Boosts are saved per profile and per site; subdomains have their own. Manage them in
**Library → Boosts**. To remove every Boost in a profile, use **Settings → Profiles →
Privacy and Security → Site Permissions → Reset Boosts…**.

## Space templates

Choose **Save Space as Template…** from the Space menu. To use one, choose **Space
Templates…** or **New Space → Use Template**, preview it, and create a Space. Templates
keep tab order, names, nested folders, split layouts, and the Space's look. You can
rename, update, or delete a template; Spaces already made from it don't change.

Templates save addresses and layout only, never cookies or passwords. Locked folders need
Touch ID or your password to save or use, and stay locked in the new Space.

## Appearance

**Themes.** Right-click a Space to edit its colours, gradient, grain, and light/dark
appearance.

**Interface style.** **Settings → General → Interface style** offers **Default** and
**Streamlined**. Streamlined tightens the sidebar and command bar. It takes effect the
next time Vane opens.

**App icon.** **Settings → Icon** offers Normal, Dark, Galaxy, Candy, Neon, Fluted Glass,
Fluted Glass Dark, Schoolbook, and Luminous. The Dock and Finder update right away. Icon
maintenance is in [AppIcons](../AppIcons/README.md).

Shortcuts are covered in [shortcut settings](BROWSING.md#shortcuts-and-keyboard-navigation).

## Settings

Press <kbd>⌘,</kbd>. Click any card's header to expand it. **General** holds everyday
choices, **Updates**, and **Previews**; **Advanced** groups Interface, Performance,
Windows and Tabs, Media, Developer, and Backup and Restore.

Passwords, privacy, website data, search engines, and extensions open in a browser tab
instead; see [Settings pages in a tab](BROWSING.md#settings-pages-in-a-tab).

## Animation and Battery Saver

**Settings → Advanced → UI Animations** sets the speed of each interface animation. Search
by name, reset one row, or **Reset All**. System Reduce Motion always wins.

**Settings → Advanced → Performance → Battery Saver** can be **Off**, **Automatic** (below
20% while unplugged), or **Always On**. When active, idle tabs sleep after five minutes,
link previews pause, and sidebar motion is reduced. Active, pinned, playing, private, and
unsaved tabs stay awake, as do sites in **Keep these sites loaded**. A small lightning
popup shows when Battery Saver turns on or off.

Web pages animate at your display's full refresh rate, including ProMotion, unless Battery
Saver or Reduce Motion is on.

## Limits

- Reader and offline saves work on articles. Very short, paywalled, or embedded content
  isn't captured. The queue holds up to 1,000 articles per profile, 20 MB each; some
  images may be missing.
- Private windows can't save to the Reading Queue, create Easels, or save captures to
  Library.
- Translation works one text block at a time (up to 5,000 per page) and skips iframes,
  shadow DOM, and text added after translating.
- Full-page captures skip infinite-scroll content that hasn't loaded.
- Easel images over 8 MB, 16,000 pixels on a side, or 32 megapixels are refused.
- Boost changes may need redoing when a site changes its markup. CSS `@import` isn't
  supported, and shadow-root contents can't be zapped.
- Moving a Space to another profile leaves its Easels with the original profile.
