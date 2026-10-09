# Vane documentation

Start with the [project README](../README.md) for installation, a local build,
and a compact overview. These Markdown guides describe current controls and
limitations. The [website field guide](https://notnaki.github.io/vane/docs.html)
remains a separate visual introduction.

## User guides

| Guide | Find answers about |
| --- | --- |
| [Everyday browsing](BROWSING.md) | Tabs, folders, Spaces, shared windows, search, keyboard navigation, Library, downloads, and Picture in Picture. |
| [Reading and customization](FEATURES.md) | Reader, saved articles, Easels, capture, Boosts, Space templates, themes/icons, and Battery Saver. |
| [Profiles, data, and privacy](DATA-AND-PRIVACY.md) | Passwords, browser imports, exports, website data, backup/restore, save failures, private browsing, and folder locks. |
| [Extensions and integrations](INTEGRATIONS.md) | Unpacked extensions, access/diagnostics, filter subscriptions, permissions, AI providers/keys, and GitHub Live Folders. |

For a paused page after an interruption, read [crash recovery](CRASH-RECOVERY.md).
For work that must stay live, read [draft-protection limits](DRAFT-PROTECTION.md).
For an interrupted transfer, read [download behavior and limits](DOWNLOAD-RELIABILITY.md#behavior-and-limits).
For blurry Google Docs canvases, read the [rendering investigation](GOOGLE-DOCS-RENDERING.md).

## Developer guides

- [Development](DEVELOPMENT.md): setup, CLI, focused validation, graphical smoke,
  project structure, and contribution workflow.
- [Releases and distribution](RELEASING.md): publishing, signing/notarization,
  updater recovery checks, and unchanged candidate verification.
- [Browser readiness](BROWSER-READINESS-TODO.md): completed work with evidence and
  remaining engineering or environment-dependent validation.
- [App icon maintenance](../AppIcons/README.md) and
  [screenshot provenance](media/README.md).

## Reliability and validation

These specialist documents retain detailed reproductions, commands, recorded
results, and caveats. A pass applies only to its stated flow, revision, and
environment. A skipped check is unverified. Implemented behavior, deterministic
fixtures, native observations, and real-service compatibility are distinct.
Historical test counts are not a fresh validation of the current checkout.

| Evidence | Scope |
| --- | --- |
| [Crash and session recovery](CRASH-RECOVERY.md) | Paused recovery, previous generations, preserved originals, multi-profile sessions, and interruption/storage fixtures. |
| [Draft protection](DRAFT-PROTECTION.md) | Live-form retention, detection failures, suspension, and nonrecoverable draft boundaries. |
| [Navigation reliability](NAVIGATION-RELIABILITY.md) | Ownership, history, cancellation, POST consent, and controlled network failures. |
| [Download reliability](DOWNLOAD-RELIABILITY.md) | Exact-byte transfers, resume/retry, destinations, restart, and safe cleanup limits. |
| [Data integration](DATA-INTEGRATION.md) | Populated cross-feature backup/restore, rollback, profile/private isolation, and storage failures. |
| [Browser data fidelity](audits/browser-data-fidelity.md) | Import/export fields, normalization, duplicates, partial failures, and credential protections. |
| [Site permissions](SITE-PERMISSIONS.md) | Document lifetimes, origin/profile scope, revocation, synthetic devices, and platform limits. |
| [Real-site compatibility](REAL-SITE-COMPATIBILITY.md) | Public demos, local fixtures, known directory-upload failure, and pending accounts/devices/provisioning. |
| [Updater recovery](UPDATER-RECOVERY-AUDIT.md) | Transaction interruption, signed recovery, notarized release acceptance, and distribution gaps. |
| [Lifecycle efficiency](LIFECYCLE-EFFICIENCY.md) | Ownership fixes, local cycle/RSS/CPU evidence, and remaining profiling work. |
| [UI responsiveness](UI-RESPONSIVENESS.md) | History and Space measurements, interaction checks, and unproven frame/latency targets. |
| [Google Docs rendering](GOOGLE-DOCS-RENDERING.md) | Safari identity and controlled canvas-density reproduction; authenticated live-document follow-up remains unverified. |

## Historical plans and website assets

[Implementation plans](superpowers/plans/) and [design specifications](superpowers/specs/)
record decisions at the time of their work. Open checklist items there may be
superseded by merged fixes and later evidence; use the readiness tracker and audits
above for current boundaries.

The public site keeps `index.html`, `docs.html`, `features.html`, `download.html`,
styles/scripts, and archived designs under `versions/`. These guides do not
rearrange that site or replace its assets. Screenshots and evidence stay at their
existing paths so links remain usable.
