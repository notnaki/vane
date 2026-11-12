# Profiles, data, and privacy

[Documentation index](README.md) · [Project README](../README.md)

This guide explains what is stored, how to move it, and what recovery can preserve.
Optional iCloud sync is available only in explicitly provisioned builds. Ordinary
local builds keep it unavailable. Cross-Mac propagation remains unverified and is
an accepted verification limitation, not a merge or release gate.

The [privacy policy](../PRIVACY.md) describes local storage, outgoing requests,
optional services, retention, and the public contact for privacy questions.

## Profiles and private browsing

Open **Settings → Profiles** to manage a profile. Use **+** to create one, the
pencil to rename it, and **Manage Profile and Spaces** for its identity and Spaces.
Use **Spaces → Profiles** to switch the browsing profile. Each Space belongs to
one profile; choosing one of its Spaces also switches that window to its profile.
The **−** control deletes the selected profile after confirmation, including its
history, bookmarks, passwords, cookies, and extensions. The last profile cannot
be deleted. Back up supported library data before deletion and export passwords
separately as CSV. Backups exclude cookies, website storage/sign-ins, and
extension code/data, including Vane's managed code copies; see the full exclusions
under Backup and restore below.

Profiles separate Spaces, history, bookmarks, passwords, WebKit website stores, and
extensions. Favourites are shared within a profile. Downloads, media, Spaces, Easels,
Boosts, archived tabs, and offline articles appear together across regular profiles
in Library; Reader preferences and content-filter sources are shared app settings.

Incognito uses a temporary identity of its own, with a glasses icon and a near-black
theme. It inherits no saved profile's Spaces, history, passwords, or extensions, and its
browsing data and download records are not restored after quitting.

Private windows do not inherit saved passwords or cloud AI, cannot save
Easels/templates/offline articles, and keep temporary site decisions and Boosts in
memory. Saving or sharing a page capture explicitly writes the chosen output. Private
browsing does not make network activity anonymous.

## iCloud choices

In a provisioned build, open **Settings → iCloud** and review the individual
categories before enabling the master switch. Your first sync preserves a local
recovery point and merges libraries. History, extension sync data, passwords and AI keys start
unselected. Controls apply independently on each Mac; turning one off keeps its
existing copies. **Remove iCloud Data** is a separate confirmed action.

Ordinary tabs and recently closed pages appear under **Other Macs**. Opening one
creates a regular local tab; remote tab closure does not close local browsing.
Download history syncs source URLs, filenames, sizes, dates and the owning Mac.
Downloaded files, local paths/grants and resume data stay local. Remote history
does not offer Open or Reveal for a file that is not on this Mac.

Saved articles have independent metadata/content switches. An article without its
offline content opens the live page; offline-only content has no invented live
origin. Easels preserve a second board for conflicting edits. Imported Boost
scripts and extension packages require local consent before execution. A separate
opt-in transfers extension-defined `storage.sync` values through public WebKit APIs;
local/session namespaces, opaque databases and grants stay local. Vendors can put
sensitive values in sync storage, and Vane cannot infer their meaning. Imported
values wait for approved local activation. Already submitted storage writes can
finish after a switch is turned off. macOS-rejected keys remain pending with a
visible error. The local extension sync shadow remains when sync is disabled;
deleted-profile entries are pruned when this category next runs its inventory.

Passwords and AI keys use separate optional iCloud Keychain mirrors, preserving
local originals and reporting conflicts. GitHub authentication, website sign-ins,
private browsing, system permissions, local file grants and biometric proofs stay
device-specific. Disabling a secret category cannot stop Apple's transport for
items already marked synchronizable. Account changes and observed cloud resets
pause affected sync until a deliberate merge/re-enable choice.

See [provisioning](ICLOUD-PROVISIONING.md) for signing/schema requirements and the
signed service validation and unverified cross-Mac coverage. Local unit tests do
not establish live service availability; missing second-Mac hardware is a
documented verification limitation, not a merge gate.

## Passwords and bookmarks

Settings → Passwords searches website/account names, sorts by website, username or recent
use, and offers account details for adding, editing, revealing, copying and deleting.
The generator supports 12–64 characters with lowercase, uppercase, number and symbol
options, including beside recognized signup/password-change fields. Saved credentials
stay in the profile’s local macOS Keychain. System authentication protects reveal/copy/edit
and existing exports; custom data directories do not bypass it. Reveals hide automatically,
and password clipboard clearing preserves anything copied subsequently.

The account chooser names the matching HTTPS origin and username. Autofill rechecks document,
origin and field identities, supports dynamic and username-first forms, and never submits.
Hidden/offscreen fields, ambiguous passwords and cross-origin frames are refused; same-origin
embedded forms need focus. Private windows do not use or save credentials.

Submission offers are explicitly unverified: Review lets you correct the website, username
and password before saving. New-account collisions require a separate update review. Visible
form rejection markers retract the attempt; submission is not proof of a successful sign-in.
Never Saved is reversible in Settings. Turn off **Offer to save passwords** in
**Settings → Passwords** to stop browser save/update offers for the selected profile.
Pending offers are dismissed. Saved-password autofill, manual edits, and imports remain available.
The setting defaults to on and is independent for each profile.

See [Password manager](PASSWORD-MANAGER.md) for controls, security boundaries, fixture evidence
and remaining real-site limitations. Passkeys remain pending Apple approval and provisioning.
The bookmark manager supports folders, search, bulk actions and HTML import/export.

## Imports and exports

Use **Vane → Import History & Bookmarks…** for supported Chromium-family browsers,
Firefox, or Safari, and **Import Passwords…** in the Passwords UI for CSV. The dedicated
**Vane → Import from Arc…** flow can also migrate supported local Arc data, including sessions;
it is separate from the general importer. Browser locations are found automatically, without a folder picker. Onboarding shows scan progress and source counts before confirmation, then imports the selected source and reports the result. macOS privacy controls may still prevent reading protected browser data; unavailable sources are reported rather than treated as empty. Review the source and destination before importing.

The general importer offers **Also copy cookies / sessions**, off by default, for Chrome,
Chromium, Edge, Brave, Vivaldi, Opera, and Arc profiles with a `Cookies` or `Network/Cookies`
database. Detected vendor locations identify the browser explicitly; Vane does not guess a Safe Storage identity from an arbitrary folder name. Onboarding’s general-browser route copies bookmarks and history; use the menu importer for optional sessions. macOS may
ask to read that browser's Safe Storage key. Only the selected browser's exact service/account
pair is read; Vane never tries other browsers' keys or creates a source Keychain item.
Firefox and Safari session extraction are not supported.

Supported session migration reads cookie database schemas 23/24 and macOS `v10` AES-CBC
values, including the host-bound format in schema 24. Other schema/encryption versions,
including `v11`/`v20`, are unsupported and reported. Cookie reads use consistent read-only
SQLite snapshots in memory, including committed WAL data. No plaintext import copy is made.
The result reports cookies imported, skipped, and failed separately; a cookie is counted as
imported only after readback verifies its value and attributes. Existing destination cookies
are kept, including host-only/domain collisions. Cancel keeps completed library batches and
verified cookie writes. A changed/deleted destination or private context stops later writes.

Cookies can carry sessions, but copying them does **not** guarantee a completed sign-in.
Site storage, device-bound credentials, passkeys and server-side session decisions can require
signing in again. Keep source browsers' existing data until you have checked the sites you use.

Import from Arc reads local SQLite snapshots and decrypts supported `v10` credentials
using Arc's Keychain Safe Storage key. Passwords keep their scheme and port; autofill
uses HTTPS and matches the full origin. Existing Vane passwords are kept, and duplicate
Arc logins use the most recently modified password (creation time in older schemas).
Arc Space emoji icons and recognized built-in icons are preserved during import.
Pinned Arc split views keep their pane order, orientation, shares, focus, and sidebar
position. Unsupported or damaged splits keep their available pages as ordinary tabs in
order; skipped sidebar row types are reported and their reachable children are preserved.
When Arc's `StorableLinkRouting.json` is present, the import confirmation also describes
Air Traffic Control rules and the external-links default. Imported rules follow existing
Vane rules, with duplicates kept once; accepted defaults replace Vane's link-opening
preference. Rules aimed at Spaces that were not imported are skipped and reported.
Missing or unreadable routing files preserve existing link settings. An explicit Space
as the default cannot be represented by Vane's current-Space/Little Vane preference;
it is reported as unsupported and the existing default is kept.
Session imports preserve HttpOnly, SameSite, Secure, domain, path, and lifetime.
Expired, partitioned, malformed, or unsupported cookies are skipped and reported. Cookies whose
lifetime or attributes cannot be represented unchanged are also rejected; those sessions
may need a fresh sign-in. No decrypted value is logged or written to an import file.

### Export files

Switch to the intended browsing profile before exporting and check the profile
named in the save panel:

| Data | Menu command | Format |
| --- | --- | --- |
| Bookmarks | **Archive → Bookmarks → Export Bookmarks…** | Netscape bookmark HTML. |
| History | **Archive → Export History (CSV)…** or **Export History (JSON)…** | One row per stored visit. |
| Passwords | **Vane → Passwords → Export Passwords…** | Plaintext CSV; type **EXPORT** to confirm. |

For editable Easel exports, see [Easel export](FEATURES.md#library-export-and-limits).
For all regular profiles and saved-library data, use [Backup and restore](#backup-and-restore).

### Import and export behavior

Password exports contain plain text credentials. Delete a CSV export when you no longer
need it. CSV imports also have a [CLI command](DEVELOPMENT.md#command-line). CSV imports preserve
existing passwords, keep the first successfully saved duplicate, and report
invalid/skipped rows and Keychain write failures. Malformed CSV quoting fails before any
saves. A password export fails if any owned credential cannot be read.

Bookmark HTML retains titles, URLs, whole-second dates and readable folder paths; nested
paths become one `Parent / Child` folder. Native browser bookmark imports retain URLs, titles and readable folder paths; Chromium and
Firefox creation dates are preserved when available. Source root containers are omitted; nested
folders become one `Parent / Child` folder, and empty folders are not imported. Safari bookmarks
without creation dates use import-time dates. Browser history imports retain each available visit and
deduplicate by URL and timestamp, so repeated imports add nothing. A failure reading or
saving either selected browser category leaves both categories unchanged. History
CSV/JSON files are export formats; they have no user-facing file importer. See [browser
data fidelity and unsupported fields](audits/browser-data-fidelity.md) for
normalization, duplicate rules, synthetic coverage and failure behavior. See also the
[Chromium session import coverage](audits/chromium-session-import.md) for browser identities,
synthetic decryption and cookie-store tests, and remaining UI/account compatibility checks.

## Website data

**Settings → Profiles → Website Data** (also in Privacy and Security) lists the selected
profile’s stored website data. Search for a site, select its available categories, and
choose **Clear Selected Data…**. **Site Controls → Clear Site Data…** opens the same
view focused on the current site. WebKit groups sites by registrable domain, so an entry
can include subdomains. Public WebKit APIs do not expose reliable per-site byte counts
on macOS 27; the view labels disk usage unavailable.

Clearing cookies or storage can sign you out or remove offline website work. Close that
site’s tabs first: live pages can retain state and recreate data. The view waits for
removal, fetches a fresh snapshot, and reports retained data or an unverified result
instead of announcing success early. A slow operation remains pending. History,
bookmarks, saved passwords and Vane’s site settings are kept. Private site controls
inspect only that tab’s temporary store, without opening a saved profile’s store. Bulk
browsing-data clearing also waits for WebKit completion and keeps shared app-opening
permissions.

```sh
swift test --filter 'WebsiteDataTests|WebsiteDataWebKitTests|ProfilePersistenceTests'
```

## Backup and restore

Settings → Advanced → **Backup and Restore** exports one `.vanebackup` file with all
regular profiles, Spaces, saved tabs and sessions, bookmark folders and bookmarks,
history, Space templates, offline articles with captured images and read state, settings
(including Reader preferences and profile-scoped site Boosts), imported blocking lists,
and Easels with embedded images. Exports offer password encryption and are limited to 512 MB;
oversized backups fail without omitting data. Passwords and tokens in Keychain, cookies
and website sign-ins/storage, downloaded files, caches, and extension code/data are
excluded, including external source folders and Vane's managed extension copies and
installation index. External folder choices are remembered, but another Mac may require
you to select and review those folders again. These backups do not restore an extension's
working code or `storage.local` settings.

**Export Backup…** offers **Export Encrypted** by default, with a password and confirmation.
Use a long, unique password and keep it safe: Vane cannot recover it. **Export Without Password**
remains available. Encrypted exports protect the entire archive with AES-256-GCM and a
PBKDF2-HMAC-SHA256 key derived with a fresh 16-byte salt and 600,000 iterations. No plaintext
export file is created. Older unencrypted backups remain readable; older Vane versions cannot
open encrypted exports.

**Restore Backup…** asks for the password of an encrypted export, then validates the file and shows its date, profiles, item counts, and
current saved-library totals before replacing anything. Cancel leaves the library alone.
**Restore and Restart** preserves a local recovery point, then restores all saved
profiles and settings during a controlled restart. It replaces the library; it does not
merge it. An interrupted restore rolls back before normal startup.

Restored Boost scripts retain their source but start disabled until you enable them
again. Certificate exceptions, camera/microphone/location answers, external-app grants,
HTTP downgrade exceptions, and extension permission approval require fresh consent after
a restore. Exact rollback after an interrupted restore preserves your original decisions.

Vane creates a recovery point after startup and checks hourly while running, saving
another only when saved data changes. The latest ten completed points are kept under the
data folder's `Recovery/Points`, including points made before restores. The last healthy
point is protected if damaged originals need preserving. Preview and restore them from
the same Settings section. A write failure keeps previous points and shows an error with
Retry. These local copies are unencrypted and share your disk: export to another disk for protection against
disk loss. **Erase Everything…** removes local recovery points too.

Focused backup validation:

```sh
swift test --filter 'DataIntegrationTests|Backup.*Tests|SpaceTemplate.*Tests|ReadingQueue.*Tests|ProfilePersistenceTests|EaselTabTests|HistoryPersistenceTests'
```

The [cross-feature integration evidence](DATA-INTEGRATION.md) records the populated
round trip, interruption recovery, profile/private checks, and limits.

## Save failures and the data folder

Profile save failures appear in browser windows and Settings → Profiles. Unsaved profile
names, colors, new profiles, and selection changes stay in memory; **Retry Save** writes
their latest state. Quitting retries them first and asks before discarding changes that
still cannot be saved. A failed profile deletion keeps its data and must be requested
again. Failed Space changes retain the last saved list; check storage and folder access,
then repeat the change. **Data Folder** helps locate files for recovery. An unreadable
`profiles.json` is preserved: restore it from a backup, then restart Vane before editing
profiles.

## Folder locks

Right-click a sidebar folder and choose **Lock Folder** to hide all of its tabs and
nested folders. Click the locked folder to show its unlock controls in the page card.
Touch ID starts automatically when the locked page appears; touch the sensor to unlock
without clicking another button. Authentication stays inline; **More unlock options…**
opens macOS authentication, where you can choose your Mac login password. Without
available Touch ID, **Unlock folder…** is the main action and uses macOS authentication.
Settings → Profiles → Passwords → **Folder unlock method** can select **System** to open
macOS authentication directly whenever you request an unlock. If a page inside is open
when you lock, Vane replaces it with a heavily blurred, frozen backdrop and an unlock
message; the page stops running and cannot receive input. Unlocks last until you relock,
quit Vane, or the Mac locks, sleeps, or switches users. **Remove Lock…** requires fresh
authentication. Locks protect access inside Vane; they do not encrypt saved tabs,
history, or browser data, and history remains available through **Archive → View
History** or **⌘Y**.

Locking parks pages and can discard volatile form/editor state. Save valuable work
before locking; see [draft-protection limits](DRAFT-PROTECTION.md#privacy-and-limits).

## Privacy and recovery boundaries

Vane stores regular browsing data locally; local files and backups contain sensitive
URLs and content. HTTPS-only mode and certificate warnings help control connections.
Certificate exceptions apply to the accepted certificate and site scope; a changed
certificate needs another decision.

[Crash recovery](CRASH-RECOVERY.md) describes previous generations, preserved originals, and manual recovery precautions. [Draft protection](DRAFT-PROTECTION.md) keeps eligible live forms awake; drafts are not written to disk or backed up.

For what leaves the Mac, see [AI connections, shared metadata and
credentials](INTEGRATIONS.md#ai-connections-and-feature-routing), [filter
subscriptions](INTEGRATIONS.md#content-blocking-and-filter-subscriptions), and [GitHub
Live Folders](INTEGRATIONS.md#github-live-folders).

AI features are off by default until enabled in onboarding or Settings → Max. Existing explicit choices are retained. Browser discovery includes Zen and Orion alongside the existing sources, reports macOS-blocked locations, and shows the selected source’s reviewed items before confirmation. Read-only sandbox access remains limited to these known browser locations; macOS privacy controls still apply.
