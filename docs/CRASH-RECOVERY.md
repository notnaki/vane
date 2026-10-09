# Crash and session recovery

Vane saves regular windows on clean quit, on window close, and every 30 seconds
while running. A successful write publishes a complete file atomically. Force Quit,
SIGKILL, SIGTERM, logout termination, and a native crash leave the same dirty
marker; Vane cannot distinguish their causes.

After an unclean exit, **Continue where I left off** restores saved windows with
their pages paused. **Ask me** offers the same recovery. **Start fresh** skips the
window snapshot. Pages restored from Spaces during that unclean launch also stay
paused. Select a badged tab and choose **Open Page**, or use Reload, to open its
saved URL explicitly. No timer or tab selection retries the page. Another failure
returns it to the paused state.

WebKit content-process termination uses the same native paused view for active
tabs, background tabs, and split panes. It retires the dead view and clears its
media, permission-document, upload, and password chooser state. Other tabs remain
usable. The recovery pause survives session and Space-sidecar saves, including a
subsequent clean quit.

## Saved files and originals

Files live in Vane's Application Support directory inside its macOS container.
Development copies using `VANE_DATA_DIR` use that directory and their own
preferences/WebKit identities.

- `session.json` and `session-<profile UUID>.json` contain per-profile windows.
  A valid primary wins; a damaged, missing, or unsupported primary falls back to
  its validated `.json.previous` generation. Reads do not replace the primary.
- Session writes first preserve the valid old primary as `.json.previous`, then
  atomically publish the new primary. Failure in either step leaves the primary
  intact. A damaged or unsupported primary is copied to a unique
  `.json.damaged-<UUID>` sibling before replacement; failure to preserve it stops
  the write. Unreadable originals are never replaced.
- Space interaction-state sidecars use the same previous-generation and damaged
  original protection. Pages recovered from a sidecar fallback stay paused.
- Before an unclean launch can restore or save anything, `Session Recovery/<UUID>/`
  receives independent copies of existing session generations, Space definitions,
  Space sidecars, and the profile list. Every repeated unclean launch creates a
  new directory. Earlier originals remain intact even if a later healthy snapshot
  is published. If those copies or the dirty marker cannot be written, startup
  stops with a storage/access message.

These local copies are retained for manual recovery; they are not automatically
pruned or included as extra generations in exported backups. They contain regular
browsing URLs and potentially opaque WebKit state. Treat them like the browser
library. Quit Vane before examining or replacing files, preserve a copy of the
whole directory first, and keep session/Space files from the same recovery
directory together. The backup restore UI is the supported way to restore a
complete library backup. Local copies cannot protect against loss of the disk.

## Recovery boundaries

| State | What comes back |
| --- | --- |
| Regular profiles/windows | Every regular profile's most recently saved window rows; active profile opens last. Profiles may have been saved at different times. |
| Tabs, pinned pages, duplicates | Saved identities, order, current URLs, pinned home URLs, names, selected tab, and supported splits with orientation and divider sizes. |
| Vane Spaces | Saved Space identities and definitions, plus available sidecars. Deleted/moved Spaces are not resurrected by stale window rows. |
| macOS desktop Spaces/window geometry | Desktop assignment, window placement, and fullscreen arrangement are not recorded by the session format. |
| Navigation history/scroll | Best effort through WebKit's opaque interaction state on ordinary clean restoration. Crash/fallback recovery opens a fresh URL instead of replaying that state. |
| Forms and transactions | Unsaved form input, JavaScript memory, file-upload selections, live calls, and in-flight transactions cannot be recovered. Open Page makes a fresh GET, never replays a saved POST body. A POST-only result page may require returning to the site's form. |
| Recent changes/storage failures | Changes since the last successful snapshot can be lost. The 30-second bound applies only while saves succeed; failures can make saved state older. |
| Private/Little Vane | Private windows, private tab state, and Little Vane windows are excluded from session saving. Private data is not added to crash archives. |

Atomic replacement prevents a process interruption from publishing a partial JSON
file. It does not guarantee recovery after hardware failure or loss of unflushed
writes. Session files and Space files are separate publications, not a transaction
across all profiles. With no valid primary or previous generation, Vane cannot
reconstruct missing bytes; damaged originals and library recovery points may help.

## Synthetic checks

```sh
swift test --filter 'CrashRecoveryTests|SessionRestoreCompatibilityTests|ProfilePersistenceTests'
./.build/debug/vane selfcheck --pure
python3 scripts/check-browser-smoke.py --crash-recovery
python3 scripts/test-crash-recovery.py
```

The scripts create disposable signed sandbox app copies and synthetic data under
Downloads. They record bundle/executable identity, PID, and process start time;
revalidate owned targets before signals; verify app exit; and unregister only
their isolated WebKit stores. They never open the regular browser library.

The macOS 27.0.1 investigation reproduced missing previous-generation fallback,
omitted windows from other regular profiles, dead views retained after termination,
and automatic page loading after repeated app interruption. Coverage includes
staged-write/out-of-space failure injection, inaccessible storage, corrupt/future
JSON, multiwindow/profile/Space/pin/duplicate/split round trips, private exclusions,
SIGKILL/SIGTERM, and repeated restoration interruptions. Physical power loss and
OS desktop-Space assignment are outside these checks.
