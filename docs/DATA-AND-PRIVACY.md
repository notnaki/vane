# Profiles, data, and privacy

[Documentation index](README.md) · [Project README](../README.md)

This guide explains what is stored, how to move it, and what recovery can preserve.
Nothing syncs between Macs.

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
separately as CSV. Backups exclude cookies, website storage/sign-ins, and external
extension code; see the full exclusions under Backup and restore below.

Profiles separate Spaces, history, bookmarks, passwords, WebKit website stores, and
extensions. Favourites are shared within a profile. Downloads and media intentionally
appear together across regular profiles in Library; Reader preferences and
content-filter sources are shared app settings.

Incognito uses a temporary identity of its own, with a glasses icon and a near-black
theme. It inherits no saved profile's Spaces, history, passwords, or extensions, and its
browsing data and download records are not restored after quitting.

Private windows do not inherit saved passwords or cloud AI, cannot save
Easels/templates/offline articles, and keep temporary site decisions and Boosts in
memory. Saving or sharing a page capture explicitly writes the chosen output. Private
browsing does not make network activity anonymous.

## Passwords and bookmarks

Settings → Passwords lets you search by website and username, add, edit, reveal, copy,
and delete saved logins. Add/edit forms can generate random passwords of 16, 20, 24, or
32 characters. The autofill chooser shows each account with a masked password; use the
arrow keys and Return to choose, or Escape to dismiss. Save and update prompts show
labeled credentials with a password reveal control. Credentials stay in the local macOS
Keychain and are scoped to the profile; private browsing does not use saved passwords.
Username-first sign-ins keep the selected account through form replacement or the next
same-origin password page. Fields revealed or mounted by a site are discovered
automatically, and same-origin embedded login forms use their own fields and chooser
anchors. Hidden fields and one-time codes are excluded from filling; cross-origin and
opaque sandbox frames cannot receive credentials. The bookmark manager supports folders,
search, bulk actions, and HTML import/export.

Autofill uses HTTPS and the full origin, never submits the form for you, and remains
heuristic. Unusual or unsupported forms can require manual entry. Passkeys remain
pending approval and provisioning; see [compatibility
prerequisites](REAL-SITE-COMPATIBILITY.md#known-pending-authentication-and-compatibility).

## Imports and exports

Use **Vane → Import History & Bookmarks…** for supported Chromium-family browsers,
Firefox, or Safari, and **Import Passwords…** in the Passwords UI for CSV. The dedicated
**Vane → Import from Arc…** flow can also migrate supported local Arc data, including sessions;
it is separate from the general bookmark/history importer. Review its selections and
confirmation before importing.

Import from Arc reads local SQLite snapshots and decrypts supported `v10` credentials
using Arc's Keychain Safe Storage key. Passwords keep their scheme and port; autofill
uses HTTPS and matches the full origin. Existing Vane passwords are kept, and duplicate
Arc logins use the most recently modified password (creation time in older schemas).
Session imports preserve HttpOnly, SameSite, Secure, domain, path, and lifetime.
Expired, partitioned, or unsupported cookies are skipped and reported; those sessions
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
paths become one `Parent / Child` folder. Native browser bookmark imports currently
retain only URLs and titles. Browser history imports retain each available visit and
deduplicate by URL and timestamp, so repeated imports add nothing. A failure reading or
saving either selected browser category leaves both categories unchanged. History
CSV/JSON files are export formats; they have no user-facing file importer. See [browser
data fidelity and unsupported fields](audits/browser-data-fidelity.md) for
normalization, duplicate rules, synthetic coverage and failure behavior.

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
and Easels with embedded images. Backups are unencrypted and limited to 512 MB;
oversized backups fail without omitting data. Passwords and tokens in Keychain, cookies
and website sign-ins/storage, downloaded files, caches, and external extension folders
are excluded. External folder choices are remembered, but another Mac may require you to
select those folders again.

**Restore Backup…** validates the file and shows its date, profiles, item counts, and
current saved-library totals before replacing anything. Cancel leaves the library alone.
**Restore and Restart** preserves a local recovery point, then restores all saved
profiles and settings during a controlled restart. It replaces the library; it does not
merge it. An interrupted restore rolls back before normal startup.

Vane creates a recovery point after startup and checks hourly while running, saving
another only when saved data changes. The latest ten completed points are kept under the
data folder's `Recovery/Points`, including points made before restores. The last healthy
point is protected if damaged originals need preserving. Preview and restore them from
the same Settings section. A write failure keeps previous points and shows an error with
Retry. These local copies share your disk: export to another disk for protection against
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
history, or browser data, and history remains available in the Library.

Locking parks pages and can discard volatile form/editor state. Save valuable work
before locking; see [draft-protection limits](DRAFT-PROTECTION.md#privacy-and-limits).

## Privacy and recovery boundaries

Vane stores regular browsing data locally; local files and backups contain sensitive
URLs and content. HTTPS-only mode and certificate warnings help control connections.
Certificate exceptions apply to the accepted certificate and site scope; a changed
certificate needs another decision.

[Crash recovery](CRASH-RECOVERY.md) describes previous generations, preserved originals, and manual recovery precautions. [Draft protection](DRAFT-PROTECTION.md) keeps eligible live forms awake; drafts are not written to disk or backed up.

For what leaves the Mac, see [AI provider metadata and
keys](INTEGRATIONS.md#ai-providers-and-your-own-keys), [filter
subscriptions](INTEGRATIONS.md#content-blocking-and-filter-subscriptions), and [GitHub
Live Folders](INTEGRATIONS.md#github-live-folders).
