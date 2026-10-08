# Cross-feature persistence and data correctness

Test host: macOS 27.0.1 (26A434), Apple Silicon, Xcode's macOS 27 SDK.
Synthetic data only; temporary data directories and private UserDefaults suites.
Baseline: `dee7b89` from latest `origin/main` on 2026-10-08.

## Scope checked against the implementation

| Feature | Complete backup contents | Isolation and exclusions |
| --- | --- | --- |
| Space templates | Profile-owned template records, appearance, tab identities/names, folders and supported split layouts | Templates belong to their profile; private/Little Vane saving is unavailable. Local Easels, files and blank pages are excluded; credentials in URLs and live-folder sources are removed. |
| Offline articles | Published article records, captured image bytes, capture date, source, and explicit read state | Profile-owned; private persistence/access and unpublished staging are excluded. Saved views use captured resources, with no live image fetch. |
| Easels | Profile-owned board identities, notes, shapes, drawing and embedded images; saved Space/session references | Private capture persistence is unavailable. References cannot point to another profile's board. External live-page content itself is not archived. |
| Reader preferences | Font size, serif choice, line spacing and reading width in settings | Shared across profiles, including private Reader views; the preferences are not private browsing records. |
| Site Boosts | Profile-specific settings records, exact origins, visual rules, hidden selectors, CSS, script text and enabled state | Schemes, subdomains and nondefault ports stay distinct. Private Boosts remain in the tab's memory and disappear on teardown. |
| Backup/recovery | All regular profiles and owned files/settings, including closed profiles | Keychain secrets, cookies/website storage, downloaded files, caches and external extension code are excluded. Device-local recovery/startup bookkeeping is retained on restore. |

## Automated evidence

`DataIntegrationTests` adds eight checks using the real repositories and backup
controller/transaction, alongside the existing feature tests:

- Populate two profiles with template-created Spaces, duplicate tabs and split
  weights, Easel tabs and embedded image bytes, offline articles with captured
  images and different read states, distinct Boosts, and shared Reader settings.
  Export a real `.vanebackup`, delete the owned inventory, replace settings, restore
  through `recoverAtLaunch`, and reopen every store twice. Compare original file
  bytes, decoded models, image bytes and settings values.
- Interrupt every exposed checkpoint of a populated replacement, including
  removal and installation of nested article resources, settings application and
  durable commit. Reopen recovery: precommit interruptions restore the complete
  original inventory/settings; postcommit recovery retains the incoming inventory.
- Reject missing/cross-profile Easel references before touching the target.
- Reject corrupt backup input and unavailable export/recovery storage through the
  controller; assert feedback, no restart and unchanged inventory/settings.
- Make the fixture storage unavailable during template, Easel and article saves.
  The saved snapshots and in-memory inventories survive; restored storage permits
  retry. Existing save tests also inject out-of-space and interrupted publication
  failures, preserve corrupt files, and verify unpublished staging exclusion.
- Verify private template/article attempts cannot publish and private Boosts
  change neither persisted settings nor another private tab.

Confirmed defect: backup validation accepted unreadable site Boost settings.
The runtime treats unreadable records as an empty table, so a restore could appear
successful while hiding the backed-up Boosts. Validation now rejects malformed
JSON, wrong preference types and noncanonical origins before staging a restore.
A damaged current library can still be repaired with a healthy backup: its raw
Boost settings are preserved in the pre-restore recovery point. Existing runtime
sanitization and valid Boost formats remain unchanged.

Validation on 2026-10-08:

```sh
swift test --filter 'DataIntegrationTests|Backup.*Tests|ProfilePersistenceTests|HistoryPersistenceTests|SpaceTemplate.*Tests|ReadingQueue.*Tests|SavedReaderTests|ReaderTests|EaselTests|EaselTabTests|SiteBoost.*Tests'
./.build/debug/vane selfcheck --pure
```

197 tests passed, one opt-in public Reader-page test skipped, zero failures.
Pure selfcheck passed. The corrupt-Boost regressions were observed failing before
the fix and passing afterward.
The initial PR CI also passed its full 829-test suite (13 skips) and packaging checks.
After incorporating the smoothness merge `b92602e`, the focused 197-test run,
pure selfcheck and debug app build passed again. CI on combined head `8a271be`
passed 874 tests (22 skips), zero failures, and packaging checks.

## Native combined verification

The initial native pass used a unique test bundle and a synthetic fixture under
an isolated data-directory override. The saved article opened with its original
content and 27-point Reader setting; the Easel showed its original note and image.
Native export produced a populated backup. Selecting corrupt input displayed
“The backup file could not be read” without restarting; all eight template,
Easel, article and image files still matched the exported bytes. The test app
was quit and its process exit verified before releasing the shared UI slot.

The sandboxed XPC file picker was inaccessible to computer-use. Export/restore
UI automation therefore uses a dedicated unsandboxed debug copy with the same
isolated data-directory override and a private settings suite. This is not a
claim that sandboxed file-picker interaction has been verified; CI separately
checks the packaged sandbox entitlements.

The final native pass used combined head `8a271be`, including the smoothness
merge `b92602e`, in the explicitly released foreground slot. With the app stopped,
the two profiles' templates and articles were deleted, Easel notes/titles were
changed, Boost tables were emptied, and Reader settings were replaced. The
native restore preview showed the original two profiles and their inventory.
Restore and Restart exited the old process and launched a replacement retaining
the isolated storage override.

Before further UI interaction, all eight template/Easel/article/image files
matched the native export byte for byte; Reader and both profile Boost settings
matched exactly. Both profiles' Space identities, URLs, custom tab names,
membership and 30/70 split weights matched. After another confirmed quit and
explicit launch, these comparisons passed again. Unnamed tab labels normalize
from null to an empty string on save; their displayed meaning stays unchanged.

The restored Personal template preview showed two tabs, one 30/70 split and
one excluded local Easel. Both profiles' Easels displayed their own original note
and embedded image. After stopping the fixture HTTP server, each profile's saved
article displayed its distinct original offline body; Personal remained unread
and Research read. Research's Reader menu reported the restored 27-point setting.
Boost records were compared through persisted settings and automated tests;
native editor interaction was not verified because computer-use activation of
the Boost row opened the Website Data window instead. No data-clear action was
performed, and this observation does not establish the cause of the mismatch.

All tracked app instances and the fixture server exited. The task app bundle,
fixtures, settings suites, WebKit and cache directories were removed. macOS
retained only the test container's protected metadata plist; its Data directory
was removed. The regular app and other tasks' instances were left running.

## Remaining limits

- Interrupted operations are deterministic checkpoint/fault tests, not a physical
  power-loss or disk-removal endurance test. Atomic publication and durable restore
  journals reduce risk; this pass does not certify every filesystem or disk.
- UserDefaults-backed Reader/Boost editing retains Foundation's normal persistence
  behavior. This pass verifies backup/restore and restart contents, not per-edit
  out-of-space feedback for every settings key. Broader settings/history save
  hardening remains open.
- macOS 26, migration to another Mac, authenticated image downloads, external
  extension folders, real accounts and physical storage failure need separate
  environments. All validation fixtures were synthetic; the regular app's data
  and preferences were not modified.
