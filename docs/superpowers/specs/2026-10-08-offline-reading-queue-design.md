# Offline reading queue

Date: 2026-10-08
Status: approved design written as a specification for review.

## Intent and scope

Let a regular-profile user explicitly save a readable article, read the captured
content without a connection, search its text, mark it read or unread, and remove
it. Preserve its title, source URL, capture date, byline when present, and practical
article images. Make the saved copy visibly distinct from the live website.

Build on Reader extraction/rendering and Library navigation. Use supported public
Foundation, AppKit, SwiftUI, ImageIO, and WebKit APIs. Add no dependency or private
WebKit API. Validate on macOS 27 while retaining the project's macOS 26 deployment
target. This is an article queue, not a general web-page archiver: interactive apps,
PDFs, media, login screens, and pages without enough extracted article text are
unsupported. Saving never bypasses authentication or expands a paywall.

The user approved the proposed sanitized Reader snapshots, Library queue with
search/read-state/storage controls, profile isolation, atomic publication, private
browsing exclusion, Reader preferences, backup integration, and motion policies.

## Selected approach

Store a validated article tree and local image resources, then generate the saved
Reader document from those values. This reuses Reader's whitelist and escaping
instead of persisting executable page markup. Full-page WebArchives retain more
page baggage and do not directly provide the desired Reader experience; screenshots
do not offer searchable article text or reusable reading preferences.

Keep four responsibilities separate:

- Article model/codec: versioned metadata, normalized Reader content, resource
  references, bounds, and validation shared by storage and backups.
- Capture service: extract the current regular page, collect bounded images, and
  return a complete candidate without altering the live page.
- Profile repository: publish candidates, persist read state, remove articles,
  provide immutable search input, and report failures and disk usage.
- Library and saved Reader UI: browse/search the queue and read a selected snapshot.

## Save flow

Add Save for Offline to the existing Reader/page controls and the application menu.
It is available for regular HTTP/HTTPS tabs, including an article already in Reader.
Retain the normalized extraction when Reader is entered so saving an active Reader
does not extract its generated header as article content. Clear retained content
when the tab navigates or closes, using the existing lifecycle hooks.

The command initiates extraction and shows Saving… without replacing the live DOM.
Reuse Reader's article suitability decision; availability hints are not proof that
a later extraction will succeed. At extraction completion and before publication,
check that the requesting tab, web view, URL/document identity, and profile are still
the ones captured. Closing/navigating the tab, deleting the profile, or invalidating
the repository cancels publication. Failed, cancelled, or unsupported captures
produce no visible queue entry. Unsupported pages explain that no readable article
was found; extraction and storage failures show a reason and an explicit retry.

New saves are unread. Opening a snapshot does not silently mark it read. An exact
source-URL match already in the queue reports Already Saved and offers opening the
existing snapshot; it does not silently replace content or change its capture date.
The user can remove and save again to capture an updated copy. Disable overlapping
saves for the same profile/source URL and coalesce duplicate requests.

Private windows show a disabled save command explaining that offline saving is
unavailable in private browsing. They cannot access the queue section or persistent
queue repositories. Enforce this in the capture/repository entry points as well as
the UI, before filesystem access or image fetching. Never stage private articles,
read regular-profile queue content into a private window, or route a private action
through the globally active regular profile.

## Image capture and offline rendering

Resolve article image URLs relative to the captured source. Deduplicate them and
download only HTTP/HTTPS resources through an ephemeral URLSession without shared
cookie storage, credentials, or disk caching. Fetches are best effort: images
requiring authentication, failing downloads, or exceeding bounds are omitted with
a visible Images unavailable summary after a successful text save. Do not retain
remote image references in the saved rendering as a network fallback.

Bound each download while streaming, including responses with missing or incorrect
Content-Length, and validate redirects' schemes. Allow at most five redirects,
15 seconds per resource, and 60 seconds total for image collection. Decode with ImageIO, validate
pixel dimensions, and store a supported raster representation; reject SVG, HTML,
scripted resources, and unrecognized bytes. Initial limits are 5 MiB per image,
20 unique images per article, 40 megapixels per decoded image, 2 MiB of UTF-8 article
text, 4 MiB for article.json, 20 MiB for a completed snapshot, and 1,000 snapshots
per profile. Bound trees to 50,000 nodes and 64 levels, and individual URL/attribute
strings to 16 KiB before recursive rendering. Exceeding the text or
snapshot/count limit fails clearly; exceeding image limits omits those images with
the partial-image notice. Never silently truncate article text.

Display saved articles in a dedicated saved Reader window associated with the
owning profile, using a nonpersistent WKWebView with page JavaScript disabled.
Generate HTML from the validated tree and current Reader preferences. Use the
existing Reader typography/style generator and preference controls, including
line spacing and reading width if introduced by the active Reader work. Do not
freeze font/style settings into the persisted article or create a second defaults
namespace. Preference changes apply to the open saved Reader.

Only explicitly mapped local images can load. A restrictive content security
policy and navigation policy prevent remote subresources, scripts, frames, forms,
and automatic navigations. Grant file read access only to the selected article's
directory through the public WebKit file-loading API. Never grant the data root.
Links and Open Live Page are explicit user actions that open ordinary browser tabs;
the saved view cannot follow them automatically or silently reload the live page.

A persistent Saved copy label shows capture date, source host/link, and any missing
image notice. The source action is titled Open Live Page. The window title and
accessible labels also identify saved content. Saved content does not enter live
browsing history, session restore, or site Boost/extension/script injection paths.
Closing the saved window releases its web view and observations. Removing its
article or deleting its profile closes/clears the view safely.

## Storage and atomicity

Store under Store.directory/ReadingQueue/<profile UUID lowercase>/<article UUID
lowercase>/. Each published directory contains article.json and an optional images
directory with generated resource IDs and validated raster extensions. article.json
contains schema version, article ID, profile ID, source URL, title, capture date,
read state, byline, normalized nodes, resource descriptors, and missing-image count.
Derive the searchable text from those nodes so it cannot disagree with the saved
article. No raw HTML, arbitrary filenames, or external file references are stored.

Use a distinct nonpublished .staging area under ReadingQueue. Build and validate
all files there, then move the complete directory into the profile inventory on the
same volume. Publish observable UI state only after the move succeeds. Stage files
with restrictive local permissions. Clean abandoned staging on initialization;
exclude it from queue enumeration, search, usage totals, and backups. Report cleanup
failures without treating incomplete directories as saved articles.

Published content and images are immutable. A read-state change atomically replaces
only article.json, then updates observable state after success. Deletion first
removes the article from the published inventory by renaming it into staging/trash,
then releases its resources. Failed inventory mutations retain the prior visible
state and report the error. Deletion cleanup errors remain visible/retryable and
their residual bytes are included in a separate pending-cleanup usage indication.

Serialize publication, read-state replacement, deletion, and backup capture on the
main actor. Background tasks may write only unpublished staging. Search, decoding,
image work, and preparation of immutable write bytes should avoid holding up input.
Do not replace published directories on a background thread while backup enumerates
them. This provides the consistent snapshot boundary requested by backup/restore.

Validate versions, finite dates, regular-profile ownership, canonical UUID paths,
source schemes/hosts, record/directory identity, node/attribute whitelist, resource
references, size bounds, and resource decodability on load and restore. Reject
symlinks and traversal at every supported directory/file boundary. Keep damaged
originals; show a readable error with Retry and allow removal of a damaged entry.
Never overwrite a damaged record by treating the queue as empty. Deleting a profile
invalidates its repository and removes its queue using the existing profile cleanup
flow; Erase Everything removes it with the rest of Store.directory.

## Library, search, and motion

Add Reading Queue to Library's rail for regular windows. It uses the window/store's
profile ID, not whichever profile is globally active. Show title, source host,
capture date, and read/unread state. Row actions are Open Saved Copy, Mark Read or
Mark Unread, Open Live Page, and Remove. Provide All, Unread, and Read filters.
Empty and error states explain how to save/retry without placeholder rows.

Search titles, source URLs, bylines, and all saved article text with case- and
accent-insensitive matching. Run search against immutable validated input away from
the input thread and discard superseded queries/profile switches. Use the existing
Library search focus and keyboard conventions. List order is newest capture first,
with a deterministic ID tie-break. Explicit read-state changes preserve that order.

Show article count and actual disk usage for this profile in the queue, with per-row
size available in details/actions. Account for images and metadata, and expose
pending cleanup bytes when present. Refresh after successful mutations and Retry.
Keep reading and searching usable without a network connection.

Use Vane's short list/status transitions for insertions, removal, filters, and save
feedback. Animate control shape/orientation changes continuously where used.
System Reduce Motion and Battery Saver make these state changes immediate. Controls
have keyboard access, meaningful VoiceOver labels, and visible focus treatment.

## Backup/restore coordination

The active Add complete backup and restore chat confirmed its contract. Build this
integration in the queue PR after codex/backup-restore merges; do not edit that
chat's worktree. BackupArchive.File owns named immutable bytes and SHA-256 digests.
BackupPaths and BackupLibrary explicitly enumerate/validate owned entries.
BackupRestore preserves raw originals, removes owned entries absent from incoming
data, and rolls back interrupted installs. Restore runs before repositories open,
so no runtime queue-cache reload hook is needed.

Extend the exact owned-name grammar for published ReadingQueue paths; reject
.staging, unexpected names, duplicate entries, symlinks, and orphan profiles.
Capture only complete articles at the serialized boundary above. Validate the
queue model and all referenced resources during preview, and show per-profile
article counts and queue inclusion in backup disclosures. Safely create/check only
allowlisted parent directories during installation. Restore removes published
articles absent from incoming data, including when restoring an older valid backup
with no queue. Preserve original damaged queue bytes for transaction rollback.

Backups retain their 512 MiB total limit and fail without trimming. Do not lower
queue fidelity to make export succeed, omit articles silently, or include staging
or queue windows as sessions. Test image bytes, read state, capture dates, stable
IDs, absent queues, profile ownership, interrupted installs, and raw rollback.
Rebase on the merged backup implementation and resolve integration against its
actual final interfaces before review/merge. Reuse the active Reader work's final
preferences/extraction interfaces if it merges first; avoid unrelated changes.

## Verification and delivery

Baseline on macOS 27.0.1 / Swift 6.4: 33 focused ProfilePersistenceTests,
LibrarySwipeTests, and DownloadLibraryTests passed before product changes.

Add meaningful tests for multi-profile isolation, private actions performing zero
persistent writes, duplicate saves, stale navigation/profile deletion, searchable
body text, explicit read-state persistence, atomic failures, publication inventory,
cleanup usage, corruption/version/path/resource bounds, and backup round trips and
rollback. Use deterministic local article/image fixtures to verify readable offline
content, image preservation, missing-image notices, generated-document escaping,
no network fallback, restricted navigation, and current Reader preferences.

Run the debug build, focused queue/Reader/Library/profile/backup tests, and pure
selfchecks documented in README.md. Expand validation when integration failures or
broad persistence changes warrant it; required CI must pass. Verify the actual
save → Library → saved Reader → search/read-state/remove flow in a task-owned test
app with isolated VANE_DATA_DIR, including blocked network and private browsing.

Work only on codex/offline-reading-queue. Open/attach a PR with behavior and
validation results, obtain independent review of its current diff, fix findings,
and repeat relevant validation/review. Squash-merge only with current-head review,
required checks/approvals, and mergeability confirmed. Track bundle paths, PIDs,
and start times of every launched test instance; quit and verify those instances
have exited after merge or abandonment. Report PR, squash commit, validation,
practical image/extraction limits, and any unresolved blocker accurately.
