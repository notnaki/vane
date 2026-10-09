# Browser readiness: completed work and remaining gaps

Updated against merged work and recorded validation on 9 October 2026. This is a
current tracker, not a claim that every browser issue is solved. Historical plans
remain under `superpowers/`; detailed evidence stays in the linked audits.

## Storage and data recovery

**Implemented and checked in scoped fixtures:** profile/Space save feedback,
atomic template/article/Easel publication, complete backups with restore preview,
local recovery points, interruption rollback, and populated cross-feature restore.
See [data integration](DATA-INTEGRATION.md), [import/export fidelity](audits/browser-data-fidelity.md),
and [crash recovery](CRASH-RECOVERY.md). Profile-owned website-data deletion has
[focused isolation and WebKit checks](DEVELOPMENT.md#testing); the UI waits for
completion and reports retained or unverified data.

Remaining:

- Extend surfaced save failures to remaining history and UserDefaults settings
  writes; backup/restore verification does not establish per-edit write feedback.
- Broaden unavailable/corrupt/full-storage and bulk-write checks beyond covered
  paths. Physical disk loss, removal, and power failure are not certified by
  injected errors or process interruption.
- Verify migration to another Mac and minimum-macOS distribution behavior.

## Navigation, drafts, and downloads

**Implemented and checked:** navigation ownership and POST consent, paused
crash/process recovery with protected saved generations, live-draft suspension
protections, and download resume/retry/cleanup fixes. See [navigation](NAVIGATION-RELIABILITY.md),
[drafts](DRAFT-PROTECTION.md), [crash recovery](CRASH-RECOVERY.md), and
[downloads](DOWNLOAD-RELIABILITY.md) for exact reproductions and limits.

Remaining:

- Unsaved JavaScript-only, canvas, closed-shadow-root, or inaccessible editor state
  cannot reliably be detected or reconstructed after a crash. Drafts are not a
  recoverable archive; locking or explicit navigation/closure can discard them.
- Extend real remote-site/network/authentication coverage. Download resumability
  depends on server/WebKit state; unknown-length truncation and immediate-cancel
  empty-file cleanup retain the documented limits.
- Repeat the relevant checks on macOS 26 and the unchanged notarized candidate.

## Permissions and extensions

**Implemented and checked in synthetic fixtures:** camera/microphone and macOS 27
location site decisions, document-scoped Allow Once, revocation, private isolation,
installation consent, expanded-access review, extension management, and runtime
permission lifecycles. See [site permissions](SITE-PERMISSIONS.md) and
[extension controls and limitations](INTEGRATIONS.md#extensions).

Remaining:

- Verify real TCC Allow/deny/revocation, delivered location, native screen-source
  chooser behavior, audio sharing, and hardware indicators in a designated device
  session. Screen sharing stays WebKit/macOS-managed; supported per-site hooks are
  unavailable. Embedded camera/microphone/location requests deliberately fail closed.
- Broaden third-party extension and real-site testing. Synthetic MV2/MV3 fixtures
  do not certify arbitrary APIs, store compatibility, or full native popup use.
- Verify fixed extension storage identity through actual signed-app quit/relaunch;
  host recreation within XCTest is the recorded restoration evidence.

## Updater and distribution

**Implemented and checked:** journaled atomic replacement, retention of the previous
verified bundle through health, interruption recovery, rollback, authenticated XPC
handoff, and pre-bootstrap supervision. [Updater evidence](UPDATER-RECOVERY-AUDIT.md)
includes signed disposable recovery and unchanged published-release acceptance.

Remaining:

- Exercise a notarized candidate containing the current changes, including
  clean-Mac installation and upgrade/rollback. Local modified recovery candidates
  simulate notarization at the transaction boundary.
- Keep actual distribution acceptance separate from headless transaction fixtures
  and physical power-loss claims. See [release procedures](RELEASING.md).

## Lifecycle and responsiveness

**Implemented and measured locally:** closed-page/store ownership fixes, 100 tab
and 100 Little Vane cycles, 200 parked session rows, and History/Space improvements.
[Lifecycle evidence](LIFECYCLE-EFFICIENCY.md) records zero weak closed-object survivors
and passing local parent-process RSS/idle-CPU targets. [Responsiveness evidence](UI-RESPONSIVENESS.md)
records a scoped release comparison and the opt-in 100 ms History benchmark.

Remaining:

- Complete Instruments allocation/energy/wakeup profiling and WebKit helper
  accounting. Parent-process counters do not establish battery-life gains.
- Keep the lifecycle targets: zero Vane-retained closed views/windows; at least
  30 seconds settling; RSS growth no greater than the larger of 50 MB or 10% of
  baseline; average parent idle CPU below 3% over at least 60 seconds; no continuing
  work attributable to closed objects. Repeat under representative heavy sites.
- Measure end-to-end input latency and matched 60/120 Hz motion sequences; native
  drag completion and interrupted physical trackpad gestures remain unverified.
- Repeat long-duration, device/media, macOS 26, and notarized-release checks.

## Real-service compatibility and documentation

The [compatibility matrix](REAL-SITE-COMPATIBILITY.md) separates historical public
flows, later local fixtures, failures, and pending service checks. The upload picker
was implemented and single/multiple-file submissions have scoped evidence. Folder
submission still fails in standalone WebKit on the observed macOS 27.0.1 host;
Vane blocks directory selection throughout 27.0.x. Other versions remain unverified.

Remaining:

- Finish designated Google/Microsoft/GitHub sign-ins, MFA, cancellation/logout and
  relaunch, subscription streaming, and cross-network calls with appropriate test
  accounts/devices. Local challenge/call fixtures and public FairPlay demos do not
  establish those flows.
- Obtain Apple's managed browser passkey entitlement approval and matching embedded
  provisioning, then verify registration/sign-in and user authorization. The
  recorded request submission and Developer ID certificate do not grant access.
- Complete pending physical printing, large/frame uploads, native media/caption,
  extension, minimum-macOS, and unchanged notarized-release checks in the matrix.
- Keep release notes, guides, and support claims aligned with new evidence. The
  [documentation index](README.md) now separates user guides, development/release
  procedures, and audits; historical checklists are not current support promises.
