# Download reliability audit plan

Goal: Verify macOS 27 WebKit downloads using synthetic HTTP responses and repair confirmed Vane lifecycle/destination defects.

Constraints: Preserve UI, per-profile folder choices, shared regular Library and private isolation. Keep WebKit responsible for transfer/resume; never implement custom Range stitching. Use latest main in codex/download-reliability. Coordinate builds/native tests outside smoothness profiling. Review current PR head, require CI, squash merge, clean task fixtures.

1. Inspect Downloads, Library, quit lifecycle, inline checks and existing XCTest/browsercheck coverage (complete).
2. Add a controlled loopback server and real WKDownload tests: complete bytes; concurrent identical names; disconnect; pause twice; resume twice; pause then cancel/remove; ranges accepted/rejected; redirects/resource change; inaccessible/missing/write-failed destinations. Run tests against baseline before fixes.
3. Add persistence/filesystem regressions: invalid/missing blobs, interrupted reload, final-file validity, folder change, profile/private isolation. Repair only demonstrated defects; rerun focused tests after each repair.
4. Exercise actual process restart in an isolated signed bundle using persisted WebKit resume data. Record outcomes and WebKit limits. Run focused XCTest, selfcheck --pure and signed browser smoke.
5. Document evidence and remaining limits in docs/DOWNLOAD-RELIABILITY.md; push PR; independent review and fixes; required CI; squash merge. Verify owned processes/servers exited and fixtures removed.

Review focus: stale async pause/resume callbacks after cancellation/removal; completion before final-file validity; destination reservations across profiles; failed resume persistence; Save panel grants/overwrite choices; cancellation must preserve finished/user files.

## Progress and review ledger

- Baseline inspected before adding coverage. Four filesystem tests failed for real behavior defects.
- Six initial real WebKit tests: repeated Resume produced 507,904 bytes for a 262,144-byte resource; Pause/Cancel resurrected a row; removal left a partial file.
- Known-length HTTP 416 completion reproduced as zero bytes and is rejected after final-file validation.
- Initial fixes and Retry: 23 focused tests passed on macOS 27.0.1.
- Smoothness reserved profiling around 12:36 Istanbul; heavy work stopped after the in-flight build finished at 12:36:54. Independent source review and test authoring continued without builds or native automation.
- Independent preliminary review: replacement-file ownership, edited finished-file availability, private retry cookies, paused retry gate, and profile deletion need regression coverage/fixes before final review.
- Ruling: enforce expected size at transfer completion; after completion a user may edit a document, so history checks only its readable regular-file availability. Misapplying size checks would hide edited user files.
- Ruling: preserve unverified/replaced files when cleanup cannot prove ownership. Deleting another file is worse than retaining an unverified partial.
- The expanded focused suite passes 49 cases; pure selfcheck passes. Review lifecycle fixes cover pending Resume/Pause, pending manual Pause/Quit, late cancelled destination callbacks, and known-GET-only retries.
- A proposed zero-byte ownership poll was rejected during independent review. macOS WKDownload has no public creation callback; unverified empty files are retained, with a controlled foreign-file collision regression. Automatic destinations are reserved until written bytes establish a filesystem identity.
- Native full XCTest, signed running/pending-pause restart rounds and browser smoke remain queued behind updater; no task-owned native app launched yet.

- Latest review fixes exclude Retry during pending Resume/Pause, guard both retry callback gaps with operation/membership checks, retire pending/active retry children on Cancel/Remove, and reject replaced partials before Resume. All 51 focused cases pass; fixture store unregistration is verified after releasing strong references.
- First CI passed download coverage on macOS 26 but timed out in an existing reused-username-node password-autofill fixture. No failing check is treated as a pass.

- An unknown-length held transfer reproduced missing byte-count updates (fraction-only observation). Observe completedUnitCount as well; unknown-length interruption/range-retry test now passes.

- Source review approved 941533d and its CI passed. Signed running-quit and pending-pause-quit restart rounds passed hashes/state/Range/blob cleanup. All six tracked processes exited, server port closed, bundle/data fixtures removed. macOS retains an empty protected sandbox registration; its Data directory is removed.
- A prior CI run timed out waiting for WebKit to fail a known readonly folder. Preflight now rejects known missing/unwritable parents before native writes; targeted real fixtures and pure checks pass. Full slot remains queued while updater fixes a LaunchServices environment-isolation issue.
