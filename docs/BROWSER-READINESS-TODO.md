# Deferred browser-readiness work

These items were deliberately deferred after the September 2026 polish and reliability
batch. Each should ship as its own focused pull request with an independent review and
passing release checks.

## Storage hardening

- Surface storage failures instead of silently losing profile, history, or settings data.
- Keep bulk writes atomic when the data directory is locked, unavailable, corrupt, or full.
- Verify profile-owned website-data deletion cannot touch another profile or test store.

## Permission behavior

- Extend origin/profile-scoped decisions to location and screen capture where WebKit
  exposes supported permission hooks. Camera and microphone already offer window-attached
  prompts, document-scoped Allow Once, and memory-only private-tab choices.
- Broaden real-site permission lifecycle coverage beyond the camera/microphone popup,
  navigation, tab closure, and profile-reset regressions.

## Extension consent

- Installation consent and manifest expanded-access review now gate extension loading,
  with profile-scoped approvals and rejection/interruption/removal regression coverage.
- Broaden real-extension compatibility coverage, including incompatible folder updates
  and runtime permission requests against real sites.

## Updater safety

- Replace the application bundle atomically and recover from an interrupted replacement.
- Preserve the previous working bundle until the new signed bundle is verified.
- Exercise upgrade and rollback with a real notarized release candidate.

## Lifecycle cleanup

- Remove retained WebViews, Little Vane windows, delegates, observers, and media sessions
  when their owning tab or window closes.
- Exercise 100 tab/Little Vane open-close cycles and a 200-tab session under Instruments,
  then allow a 30-second idle settling period.
- Require zero closed WebViews or windows retained by Vane, a post-settling resident-memory
  increase over the pre-cycle baseline no greater than the larger of 50 MB or 10% of that
  baseline, average idle CPU below 3% over 60 seconds, and no continuing timers, media
  activity, or wakeups attributable to the closed objects.

## Final documentation and compatibility pass

- Reconcile the README, known issues, release notes, and browser-support matrix with tested
  behavior.
- Record remaining gaps for sign-in providers, passkeys, uploads, printing, streaming, DRM,
  device permissions, and clean-Mac installation.
- Keep real-account, payment, hardware, and notarized-distribution checks explicitly marked
  as requiring an appropriate test environment.
