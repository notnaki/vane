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

## Native combined verification

Pending the smoothness change's merge and the coordinated native UI window.
Automated cold repository reopens exercise the launch transaction, but are not a
claim that the native Restore and Restart flow has been checked on the combined build.

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
  environments. No user's regular Vane data or accounts were used.
