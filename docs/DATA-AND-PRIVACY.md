# Profiles, data, and privacy

[Documentation index](README.md) · [Project README](../README.md)

Vane keeps your browsing data on your Mac. This guide covers profiles, passwords,
importing and exporting, backups, folder locks, and what Vane sends elsewhere. The
[privacy policy](../PRIVACY.md) has the full list of outgoing requests and retention.

Passwords, Privacy and Security, Website Data and Clear Browsing Data open as a
[settings tab](BROWSING.md#settings-pages-in-a-tab). Reach them from the rows in
**Settings → Profiles**, or type `vane://` in the command bar. Each page has a profile
menu.

## Profiles and private browsing

A profile keeps its own Spaces, history, bookmarks, passwords, cookies and website
storage, and extensions. Favourites are shared within a profile.

- **Create, rename or delete:** **Settings → Profiles**. Use **+** to add, the pencil to
  rename, **Manage Profile and Spaces** for its Spaces, and **−** to delete.
- **Switch:** **Spaces → Profiles**, or pick one of the profile's Spaces.

Deleting a profile removes its history, bookmarks, passwords, cookies, archived tabs and
extensions, including their stored data. You can't delete the last profile. Back up
first, and export passwords separately: backups don't contain them.

Library shows downloads, media, Spaces, Easels, Boosts, archived tabs and offline articles
from every regular profile together. Reader preferences and filter-list sources are shared
by all profiles.

**Private windows** use a temporary profile with a glasses icon and a near-black theme.
They have no saved Spaces, history, passwords, extensions or cloud AI. They can't save
Easels, templates or offline articles. Site decisions, Boosts and tab-title overrides
live in memory. When the last private window closes, its website data, unfinished
downloads and download records go; files you downloaded stay on disk. Private browsing
does not hide your activity from your network or the sites you visit.

## Passwords and passkeys

Saved passwords live in your Mac's login Keychain, separately for each profile. Open
**Settings → Profiles → Passwords**, or choose **Vane → Passwords → Manage Saved
Passwords…**.

| Protection | Default |
| --- | --- |
| **Require Touch ID to view passwords**: the page stays locked until you touch the sensor or choose **Use Password…**. It locks again after five minutes idle, when you leave the page or switch profile, and when the screen locks, the Mac sleeps or you switch users. | On, app-wide |
| **Require Touch ID to fill passwords**: Vane asks before filling a password, then not again for five minutes, or until the screen locks, the Mac sleeps or you switch users. Turning it off asks first. | On, app-wide |
| Revealing, copying or editing a password always asks. Revealed passwords hide after 60 seconds; a copied password leaves the clipboard after 60 seconds unless you've copied something else. | Always |
| **Offer to save passwords** after you submit a form. Turn it off if you use an extension password manager. | On, per profile |

Delete a password and it disappears at once with **Undo** for five seconds, or press
<kbd>⌘Z</kbd>. The password generator makes 12–64 characters with your choice of
lowercase, uppercase, numbers and symbols. Vane never submits a form for you. Private
windows never read, fill or save passwords. See [Password manager](PASSWORD-MANAGER.md)
for how autofill and saving work.

**Passkeys** use the macOS passkey sheet, with Touch ID and Apple Passwords or another
passkey app you've turned on. Release builds from 0.2.4 carry Apple's browser passkey
entitlement; local builds don't, and the ⓘ beside the Passwords heading says which you have. Vane doesn't store
passkeys itself.

**Apple Passwords (iCloud Keychain)** can't fill in Vane yet. To bring them over, export a
CSV from the Passwords app, choose **Vane → Passwords → Import Passwords…**, then delete
the CSV. The copy doesn't follow later changes on your other devices.

## Imports and exports

### Import from another browser

| Source | Command | What comes across |
| --- | --- | --- |
| Arc | **Vane → Import from Arc…** | Spaces and tabs, pinned split views, Space icons, history, bookmarks, passwords, Air Traffic Control rules, and sessions (cookies) |
| Chrome, Chromium, Edge, Brave, Vivaldi, Opera, Arc, Zen, Orion, Firefox, Safari | **Vane → Import History & Bookmarks…** | History and bookmarks. For Chrome, Chromium, Edge, Brave, Vivaldi, Opera and Arc, **Also copy cookies / sessions** is offered, off by default. |
| A password CSV | **Vane → Passwords → Import Passwords…** | Website, username and password |

Vane finds each browser's data on its own and shows what it found before you confirm.
If macOS blocks a location, Vane says so rather than importing nothing. Importing again
adds no duplicate visits or bookmarks. Existing Vane passwords are always kept.

When you copy cookies, macOS asks to read that browser's Safe Storage key, and Vane reads
only that one browser's key. Decrypted values are never logged or written to a file.
Existing cookies in Vane are kept. Copied cookies don't guarantee you stay signed in:
sites can tie sign-ins to the device or to storage Vane can't copy, and passkeys don't
transfer. Keep your old browser's data until you've checked the sites you use.

From Arc, Air Traffic Control rules are added after your existing Vane rules. Rules for
Spaces you didn't import are skipped and listed. Arc's "open in a chosen Space" default has
no Vane equivalent, so your current link setting stays.

### Export files

Switch to the profile you want first; the save panel names it.

| Data | Command | Format |
| --- | --- | --- |
| Bookmarks | **Archive → Bookmarks → Export Bookmarks…** | Netscape bookmark HTML |
| History | **Archive → Export History (CSV)…** or **(JSON)…** | One row per visit |
| Passwords | **Vane → Passwords → Export Passwords…** | Plain-text CSV; type **EXPORT** to confirm |

A password export is unencrypted. Delete it when you're done. In history CSV, titles and
URLs that look like spreadsheet formulas start with an apostrophe; use JSON for exact text.
For Easels, see [Easel export](FEATURES.md#library-export-and-limits). For everything at
once, use a [backup](#backup-and-restore). There's also a
[command-line password import](DEVELOPMENT.md#command-line).

## Website data

Open **Settings → Profiles → Website Data** to see which sites have stored cookies or
other data in this profile. Search for a site, select what to remove, and choose **Clear
Selected Data…**. From a page, use **Site Controls → ⋯ → Clear Site Data…**.

Entries are grouped by domain, so one entry can include subdomains. Clearing cookies or
storage can sign you out or remove offline work. Close that site's tabs first, since an
open page can write its data back. History, bookmarks, passwords and site settings stay.
**Clear Browsing Data** removes data across sites; clearing all history also deletes local
recovery points so the history can't return in a restore.

## Backup and restore

Open **Settings → Advanced → Backup and Restore**.

**Export Backup…** saves one `.vanebackup` file with every regular profile, Space, saved
tab and session, bookmark, history, Space template, offline article, Easel, imported
filter list, and your settings, including Reader preferences and Boosts. It's encrypted
by default with a password you choose (AES-256-GCM, key from PBKDF2-HMAC-SHA256 with
600,000 iterations). Vane can't recover a lost password. **Export Without Password** is
also offered. Backups are limited to 512 MB.

A backup does **not** contain:

- passwords and tokens from the Keychain
- cookies, website sign-ins and website storage
- downloaded files and caches
- extension code and extension data

**Restore Backup…** shows the backup's date, profiles and item counts beside your current
ones before changing anything. **Restore and Restart** saves a recovery point, then
replaces your library; it doesn't merge. If a restore is interrupted, Vane rolls back at
the next launch. After a restore, Boost scripts start turned off, and certificate
exceptions, camera, microphone and location answers, app-opening grants, HTTP exceptions
and extension approvals ask again.

**Recovery points.** Vane saves one after launch and checks hourly, saving again only
when something changed. The last ten are kept in the data folder under
`Recovery/Points`, unencrypted. Preview and restore them from the same section. Export a
backup to another disk to protect against losing this one.

**Settings → Advanced → Reset Vane → Erase Everything…** deletes every profile, its
website data, Vane's passwords and sign-in credentials in the Keychain, your settings and
the recovery points, then starts Vane over. Type **ERASE** to confirm. Downloaded files and
files you exported stay.

If a profile change can't be saved, a notice appears with **Retry Save**, and Vane asks
before quitting with unsaved changes. **Data Folder** shows where the files are. See
[Crash recovery](CRASH-RECOVERY.md) for more.

## Folder locks

Right-click a sidebar folder and choose **Lock Folder**. Its tabs and nested folders hide,
and a page that was open inside is replaced by a blurred, frozen image until you unlock.

To unlock, click the folder and touch the sensor: Touch ID starts on its own. **More
unlock options…** lets you use your login password. To always use the macOS dialog, set
**Settings → Profiles → Privacy and Security → Locked Folders → Unlock folders using** to **System**. Folders
stay unlocked until you lock them again, quit Vane, or the Mac locks, sleeps or switches
users. **Remove Lock…** asks again.

Locked tabs stay out of Library, cloud AI naming and iCloud's open-tab sync. A lock
controls access inside Vane: it doesn't encrypt anything, and the folder's pages still
appear in History (<kbd>⌘Y</kbd>). Locking unloads pages, so save unfinished work first
([draft protection](DRAFT-PROTECTION.md#privacy-and-limits)).

## iCloud sync

iCloud sync is optional and available only in builds provisioned for it. Open
**Settings → iCloud**, review the categories, then turn on the main switch. The first sync
saves a local recovery point and merges, so nothing is replaced.

- **Off until you choose them:** history, passwords, AI API keys and extension sync data.
- **Always local:** private browsing, cookies and website sign-ins, website storage,
  passkeys, GitHub sign-in, downloaded files, file and permission grants, and unsaved
  forms.
- **Other Macs** lists open tabs and recently closed pages from your other Macs, plus
  completed-download details (source URL, filename, size, date). Opening one makes a
  regular local tab.
- Passwords and AI keys sync through iCloud Keychain, separately from the rest, and your
  local copies stay. Turning those categories off can't recall items iCloud Keychain
  already carries.
- With history on, clearing history also clears the synced copy.
- If this Mac's Apple Account changes, sync pauses until you choose **Review Merge…**.
- Imported Boost scripts and extensions ask before running on this Mac. Extension sync
  data covers only what an extension puts in `storage.sync`, which may be sensitive.
- Changes from your own Macs apply as they arrive. Each Mac keeps its own switches;
  turning a category off keeps the copies you have. **Remove iCloud Data…** deletes the
  cloud copy.

See [iCloud provisioning](ICLOUD-PROVISIONING.md) for build requirements.

## What leaves your Mac

Vane has no account and no Vane server. Besides the sites you visit, the main
connections are below; the [privacy policy](../PRIVACY.md) lists them all.

| Feature | Sent | Default |
| --- | --- | --- |
| App updates | Update checks to GitHub's release API; no browsing data | On |
| Search suggestions | What you type in the address bar, to the suggestion provider you choose | Off |
| Instant Links (<kbd>⇧Return</kbd>) | Your query to DuckDuckGo | On; never in private windows |
| [AI features](INTEGRATIONS.md#ai-connections-and-feature-routing) with a cloud connection | Tab titles, hostnames and download names; for summaries and Ask on Page, page text and your question. Never from private windows. | AI off; Apple on-device unless you pick a cloud connection |
| [Filter subscriptions](INTEGRATIONS.md#content-blocking-and-filter-subscriptions) | A request for each list URL you add, without cookies | Built-in list only |
| [GitHub Live Folders](INTEGRATIONS.md#github-live-folders) | Requests to GitHub with your token | Off until you create one |
| Chrome Web Store extensions | The extension ID to Google, without cookies, at install and in a daily update check | Only for store extensions you install |
| Link and favourite previews | Hovering loads the linked page, or the GitHub, Gmail or Calendar page, with your cookies. Favourite previews also refresh in the background. | On |
| iCloud sync | The categories you choose | Off |
| [Translate Page](FEATURES.md#translate-page) | Nothing: translation runs on device | Offered for pages in other languages |

**Performance data** stays on your Mac. **Settings → Advanced → Performance →
Diagnostics** shows launch time, hangs and Space-switch times, plus Apple's crash and hang
reports, kept in `performance.json` (up to 500 samples per measure). **Export…** writes an
anonymous file: timings, counts, the Vane version and day, and Apple reports with messages
and file paths removed. **Include Mac details in exports** (off) adds the Mac model, macOS
version, memory, core count and binary identifiers. **Clear** deletes it all.

HTTPS-Only mode and certificate warnings protect connections. A certificate exception
covers only the certificate you accepted.

## Limits

- Website Data can't show per-site disk usage; WebKit doesn't report it.
- Clearing site data while the site is open can be undone by the page writing it back.
- Cookie import reads Chromium cookie schemas 23 and 24 with macOS `v10` encryption;
  other formats, and Firefox and Safari cookies, are reported as unsupported.
- Bookmark imports flatten nested folders into one `Parent / Child` folder and skip empty
  folders. History CSV and JSON are export-only.
- iCloud sync between two Macs hasn't been verified; see
  [iCloud validation](ICLOUD-VALIDATION.md).
- Folder locks and Touch ID protect access inside Vane, not the files on disk.
- Evidence and deeper detail: [Password manager](PASSWORD-MANAGER.md),
  [Crash recovery](CRASH-RECOVERY.md), [Security audit](SECURITY-AUDIT.md).
