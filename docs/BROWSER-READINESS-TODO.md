# Deferred browser-readiness work

These items were deliberately deferred after the September 2026 polish and reliability
batch. Each should ship as its own focused pull request with an independent review and
passing release checks.

## Storage hardening

- Surface storage failures instead of silently losing profile, history, or settings data.
- Keep bulk writes atomic when the data directory is locked, unavailable, corrupt, or full.
- Verify profile-owned website-data deletion cannot touch another profile or test store.

## Permission behavior

- Scope camera, microphone, location, and screen-capture decisions to the requesting origin
  and profile.
- Support one-time grants and keep private-session grants in memory only.
- Verify navigation, tab closure, and profile deletion invalidate the appropriate grants.

## Extension consent

- Show permissions before installation and require review when an update expands access.
- Keep extension data and permissions isolated by profile.
- Cover rejection, interrupted installation, incompatible updates, and removal cleanup.

## Updater safety

- Replace the application bundle atomically and recover from an interrupted replacement.
- Preserve the previous working bundle until the new signed bundle is verified.
- Exercise upgrade and rollback with a real notarized release candidate.

## Lifecycle cleanup

- Remove retained WebViews, Little Vane windows, delegates, observers, and media sessions
  when their owning tab or window closes.
- Exercise 100 tab/Little Vane open-close cycles and a 200-tab session under Instruments,
  then allow a 30-second idle settling period.
- Require zero closed WebViews or windows retained by Vane, resident memory within the larger
  of 50 MB or 10% of the pre-cycle baseline, average idle CPU below 3% over 60 seconds, and no
  continuing timers, media activity, or wakeups attributable to the closed objects.

## Final documentation and compatibility pass

- Reconcile the README, known issues, release notes, and browser-support matrix with tested
  behavior.
- Record remaining gaps for sign-in providers, passkeys, uploads, printing, streaming, DRM,
  device permissions, and clean-Mac installation.
- Keep real-account, payment, hardware, and notarized-distribution checks explicitly marked
  as requiring an appropriate test environment.
