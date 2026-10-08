# Updater recovery audit — macOS 27

Audited on macOS 27.0.1 (26A434), arm64, starting from `main` at `dee7b89`
in an isolated `codex/updater-failure-recovery` worktree. The installed Vane and
its data were not modified. Heavy checks and foreground launches were scheduled
with the smoothness chat.

## Confirmed defects and fixes

- A lower-version destination could be an unrelated or damaged app. The installer
  now validates bundle shape, executable containment, Vane code identity and the
  sealed existing signature before replacement. Incoming executables must support
  the current architecture. Existing ad-hoc Vane installations retain their
  previous acceptance policy; incoming updates still require the pinned Developer ID.
- Directory inode identity survived edits and partial deletion. Journals now bind
  the canonical target, volume and SHA-256 content snapshots. Recovery and health
  decisions independently verify the bundle signature/identity as well. A damaged
  previous bundle is retained for attention rather than activated or discarded.
- Symlink and dangling-symlink journals could bypass transaction protection.
  Journals must be regular files; dangling entries remain blocking records and
  locks refuse symlinks. Stale or unbound records cannot authorize other targets.
- An old executable already running during a swap could certify the replacement.
  Kernel executable-path ownership now gates launch and health decisions.
- Finder's root `Icon\r` file changes legitimately during startup. Content snapshots
  ignore that exact root file while retaining all signed `Contents` data. Legacy
  journals can restore independently verified previous bundles even if the new
  bundle is damaged; interrupted legacy cleanup remains recoverable.
- Restart could lose `VANE_DATA_DIR` and select an existing app instance. Relaunch
  now preserves isolation and requests a new instance. The shell verifies the
  current host and helper against pinned signature requirements before execution.
  Real native testing also caught and fixed the missing `=` prefix for inline
  `codesign -R` requirements.
- A signed candidate exiting before browser bootstrap never claimed its journal,
  so repeated starts could leave it active indefinitely. A restricted mode of the
  existing installer helper watches LaunchServices' actual application object. It
  restores the verified previous bundle when that process dies before bootstrap;
  a slow live launch is allowed to continue. Once bootstrap claims the journal,
  existing browser recovery owns health and rollback. Failed opens return failure
  even when a stale or malformed record prevents recovery.
- Transport and verification failures lost diagnostic context. Known download
  lengths must match, signature errors retain Security status/details, Gatekeeper
  retains stderr/status, and filesystem errors retain errno and path.

The architecture remains URLSession/ditto, authenticated same-user XPC installation,
durable sibling staging, atomic rename/swap and prepared/launching/healthy journal.
The previous bundle is removed only after the existing AppKit/WebKit health criteria
and durable healthy record. Unsafe recovery stops before opening a browser window.

## Evidence and reproducible checks

| Area | Coverage |
| --- | --- |
| Transport/extraction | Real URLSession loopback complete, truncated, interrupted, cancellation and HTTP failure cases; real ditto corrupt/truncated/empty ZIP and missing/unsigned bundle rejection. The release host is simulated; production host trust is unchanged. |
| Transaction | 107 headless assertions, including actual SIGKILL at copy, sync, journal, swap, launch, rollback and healthy/cleanup boundaries; failed writes/destinations/replacement; repeated attempts; stale, legacy, wrong-target/volume and symlink records; damaged old/new bundles and old executing inode. Bundle verification predicates in generic directory fixtures are simulated. |
| Relaunch | Literal shell arguments, isolated environment, three failed-open retries, simulated verifier/helper failures, refusal to execute an unverified helper, and real ad-hoc `codesign` requirement parsing. |
| Distribution | Unchanged published v0.0.23 and v0.0.24 fixtures passed strict deep/all-architecture signature verification, stapled-ticket validation and real Gatekeeper assessment as Notarized Developer ID, team `T7X84HN3W3`. |
| Rejections | Real Developer ID re-signed wrong identity, version and architecture fixtures were rejected. A locally signed unnotarized candidate passed signature verification but failed real Gatekeeper assessment, preserving the old destination and detailed error. Tampered signatures were rejected. |
| XPC | Mutual caller/helper trust, unauthorized caller rejection, sandboxed source copy, final signature/Gatekeeper verification and quarantine removal tested in isolated Downloads installation directories. Task-owned clients and services were verified exited. |
| Browser regression | Final local Swift suite: 825 tests, 8 skipped, zero failures; pure selfcheck passed. Skips cover opt-in Keychain/public-network/directory-WebKit cases and animation paths while the coordinated Reduce Motion slot was active. |

Native launch results and final review/CI are recorded with the PR. The scripts are
documented in README and headless transaction/transport/relaunch checks run in CI.
Native fixtures use isolated data and disposable app copies. Their driver inherits
Vane's sandbox entitlements for the shell/helper chain. All native process signals
are limited to recorded executable paths, PIDs and start times.

## Limits

The modified candidate and early-exit executable are locally Developer ID signed,
not notarized. Their native transaction staging simulates candidate notarization;
this does not establish distribution approval for the changed build. Real
distribution acceptance above applies only to unchanged published releases.
A notarized build containing these changes and a clean-Mac upgrade remain release
prerequisites. Power loss/storage failure is represented by durable-boundary process
interruption and injected failures, not physical power removal. Invalid records or
an untrusted helper retain the previous bundle for attention rather than executing
unverified recovery code.
