# Backup and restore

Date: 2026-10-08
Status: written specification for review; product implementation has not started.

## Intent and approved direction

Protect Vane's growing saved library before adding more data-heavy features. A user
must be able to export all saved Spaces, tabs, bookmarks, settings, and Easels;
inspect a backup before restoring it; and recover a previous local state without
having remembered to export a file.

The user selected replacement after preview with a recovery point, and approved
the proposed portable backup, controlled restart, interrupted-restore rollback,
hourly recovery points when data changes, retention of the latest ten points,
and controls under Settings → Advanced. Restore does not merge libraries.

## Scope and fidelity

- Include every regular profile, profile order and active profile identity.
- Include all saved Spaces, names, themes, folders, locks, favourites, pinned tabs,
  Today tabs, splits, tab names, selected tabs, and saved window/session metadata.
  Preserve existing IDs and saved tab interaction state where available.
- Include bookmark folders and bookmarks with their identifiers and ordering.
  Include history because it shares each profile's SQLite database with bookmarks;
  disclose this in the export description and preview.
- Include the app's persistent preference domain, including per-profile settings,
  archived tabs, search engines, shortcuts, permissions, and sidebar metadata.
  Capture only Vane's own persistent domain, never global or registered defaults.
  Exclude transient startup/crash/restore bookkeeping and backup scheduling metadata.
- Include every Easel, item, drawing, style, title, and embedded image. Preserve
  board IDs so Easel tab references still point to the restored boards.
- Exclude private windows and Little Vane sessions, Keychain passwords and tokens,
  cookies, website sign-ins/storage, caches, downloaded files, and external extension
  folders. Preserve preferences referencing external folders; show that another Mac
  may require the user to select those folders again. The backup is not encrypted.

The implementation must inventory the current persisted files and preference keys
against this list. Use explicit file ownership rules; do not recursively copy the
entire Application Support directory. Unrelated files and recovery storage survive
restore. No changes to Keychain or WebKit website-data stores are required.

## Alternatives and selected architecture

A folder copy is simple but is not a consistent SQLite snapshot and misses
preferences. Independent exports for each feature make recovery incomplete and
require several manual operations. Choose one versioned archive with a shared
capture and validation service, a persistent restore transaction, and a small
Settings interface. Manual exports and automatic points use the same archive.

Use a single `.vanebackup` file encoded as a binary property list, with a format
identifier, schema version, backup UUID, creation date, app version, reason,
preference payload, and named file payloads. Each payload has a SHA-256 digest.
Store bytes as Data to avoid JSON/base64 expansion. Version 1 readers reject newer
versions with a clear message rather than partially restoring them. Use only
Foundation, CryptoKit, SQLite, and the app's existing UI frameworks; add no dependency.

Archive entries are logical names from the owned-file allowlist, not arbitrary
destination paths. Reject duplicate names, traversal, absolute paths, symlinks,
unexpected files, missing required metadata, invalid digests, and orphan profile
references. Bound archive reads to 512 MiB and total decoded payloads to 512 MiB;
report the limit without trimming any requested data. Respect existing Easel limits.

## Consistent capture

Before capture, flush pending profile changes and save all regular sessions/Spaces.
Failure to save must fail the export; never report a stale snapshot as current.
Serialize capture initiation and UI mutations on the main actor, and serialize
archive writes and automatic jobs so they cannot overlap a restore.

Use SQLite's backup API for each profile database, including uncheckpointed WAL
changes. Never copy a live database and its journal files independently. Check
database integrity on the staged snapshot. Read closed profiles without creating
new library files merely for the backup. Capture all owned JSON/preferences at
the same logical snapshot boundary. Perform encoding and output I/O away from
interactive UI work once immutable snapshot bytes have been obtained.

Exports are written atomically, with restrictive permissions. An incomplete write
never replaces a previously completed export. Only a successfully completed export
is reported as saved. Cancelling the save panel does not start a job.

## Restore preview and application

Settings → Advanced gains a Backup and Restore section with Export Backup…,
Restore Backup…, automatic recovery status, and a recovery-point list.

Selecting a file or recovery point first validates it into immutable staged bytes.
The preview shows its date and app version, per-profile names and counts for
Spaces, saved tabs, bookmarks, history entries, and Easels, plus current totals.
Count a saved tab identity once when it is represented in both session and Space
metadata; include favourites and pinned tabs without silently omitting them.
State clearly that all regular profiles' saved data and settings will be replaced,
that a recovery point is created first, and that Vane restarts. Display exclusions
and any external-folder relinking limitation. Cancellation leaves current data alone.
Validation errors disable Restore and explain the problem. A changed source file
after preview cannot change the bytes that get restored.

Restore is applied at the next controlled launch, before profile migration,
FirstLaunch, icon preferences, session restoration, or any database/repository opens:

1. Preserve the current owned files and preference domain as a pre-restore point.
   Preserve damaged current bytes as well; incoming validation must not depend on
   the current library being healthy. Mark a damaged point accordingly and disable
   restoring it as a validated library, while retaining its originals for recovery.
2. Persist a transaction journal and staged incoming archive under dedicated local
   recovery storage. Refuse restore if preserving originals or staging fails.
3. Restart only the requesting Vane instance, preserving VANE_DATA_DIR isolation.
   Flush before staging and prevent shutdown/session saves from overwriting incoming
   data. If restart cannot be initiated, clear the pending transaction and report it.
4. At launch, verify staged bytes again, record the applying phase durably, replace
   only owned library files, remove owned files absent from the incoming library,
   and apply the captured preference domain. Preserve local backup bookkeeping,
   migration markers, and unrelated app-support files.
5. Commit the transaction durably after all files and preferences are installed.
   Clean temporary staging only after commit; retain the pre-restore recovery point.
6. An interrupted applying phase rolls all owned files and preferences back to
   the preserved original bytes before normal startup. A failed rollback keeps the
   journal and originals and stops normal library initialization with a recovery
   error; it must not open a half-restored library.

Use an idempotent journal state machine. Test interruption after each mutation,
including preference application and the durable commit. Restore completion forces
one session restoration even if the backed-up reopen-tabs preference is off; retain
that preference for subsequent launches. Report successful restoration after launch.

## Automatic local recovery

Create the first valid point after startup has completed and the normal saved
library is available. While Vane is running, check hourly and create a point only
if the captured saved content differs from the last successful point. Content
comparison excludes timestamps and backup bookkeeping. Also create a point before
each restore even when the content matches the latest automatic point.

Keep the latest ten completed points total, ordered by creation time with unique
IDs for ties. Prune only after successfully writing and validating the new point;
never remove the only usable recovery point because the next write failed. Do not
include recovery points inside backups. Recovery storage belongs to the selected
data directory so test instances remain isolated. Erase Everything also removes
its local recovery points, consistent with the existing reset promise.

Show point date, reason, size, and availability in Settings. Automatic failures
show the last successful point and a concise error with Retry; they never claim
the library is protected or repeatedly interrupt browsing. Automatic jobs do not
run while restore is being prepared/applied. Local points protect against library
mistakes; exported files are necessary for recovering from loss of the Mac/disk.

## UI and platform constraints

Support macOS 26 or later. Follow existing Settings card and native file-panel
patterns. Keep progress, errors, and previews accessible. Disable overlapping
operations, show progress for long jobs, and keep cancellation available before
the user commits to restore. Animate preview/status transitions briefly using
Vane's existing motion styles; system Reduce Motion and Battery Saver make them
immediate. Never change the user's quit-confirmation preference.

## Validation and delivery

Use isolated temporary directories and preference suites. Tests must round-trip
multiple profiles, session/Space overlap, folders/favourites/pins/splits, archived
tabs/settings, SQLite WAL bookmarks/history, and Easels with image bytes and stable
IDs. Test empty libraries, closed profiles, no database yet, unrelated files, and
cross-profile reference rejection. Validate corrupt/future/oversized archives,
duplicate/path-traversal entries, malformed JSON/SQLite/Easels, and digest failure.

Inject failures at capture, archive writing, staging, file replacement, preferences,
commit, and rollback. Confirm no silent partial success and verify repeated launch
recovery. Test hourly change detection, first point, pre-restore preservation,
retention after failed writes, isolation, and restore cancellation/staged immutability.
Exercise the actual Settings preview and controlled restore/relaunch with a task-owned
Vane test bundle and isolated VANE_DATA_DIR, never the user's regular Vane data.

Run the relevant debug build, focused Swift tests, pure selfchecks, and startup
checks described in README.md. Run required CI. Open a PR on codex/backup-restore,
obtain an independent review of its latest diff, address findings, and squash-merge
only after review, required checks/approvals, and mergeability are confirmed. Track
and quit all task-owned test processes, verify merge and report its squash commit.
