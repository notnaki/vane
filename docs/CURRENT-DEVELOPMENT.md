# Current development and the upcoming release

[Documentation index](README.md) · [Project README](../README.md) · [Website guide](https://vane.so/docs.html)

This overview follows `main`, reviewed on **13 November 2026** at
[`134456ea`](https://github.com/notnaki/vane/commit/134456ea45bfb0e8158db665a691821d3f1112e1).
It describes implemented development behavior, not the contents of the latest
published release. Check an individual release's notes before expecting these
controls in an older installation. No release version or publication date is
announced here.

## What to find in the current app

| Area | Current behavior | Guide |
| --- | --- | --- |
| First launch and imports | Review discovered browsers and item counts before importing. The dedicated Arc importer can bring supported Spaces, pins, splits, passwords and sessions; the general importer has a separate, optional Chromium cookie/session copy. | [Imports and exports](DATA-AND-PRIVACY.md#imports-and-exports) |
| Browsing and organization | Shared Space state, compact windows and search, nested folders, reviewed Tidy proposals, clean-link copying, and inline Library filters. Window and sidebar resizing retain painted page content. | [Everyday browsing](BROWSING.md) |
| Previews and Max | Link cards show page metadata and can add a summary when Max and its selected connection are available. Assign tab naming, grouping, download naming and summaries separately to on-device Apple, an API connection or an eligible ChatGPT connection. AI features start off until enabled. | [AI connections and routing](INTEGRATIONS.md#ai-connections-and-feature-routing) |
| Reading and visual tools | Reader, saved offline articles, page captures, Easels, Boosts and reusable Space templates. | [Reading and customization](FEATURES.md) |
| Settings | General groups everyday controls; Advanced groups its categories. Search individual UI animations and adjust their speed, with Reduce Motion and Battery Saver taking priority. | [Settings](FEATURES.md#settings) |
| Optional iCloud | Provisioned builds offer per-category CloudKit sync and separate password/API-key Keychain choices. Sync is off initially; private browsing and website sign-ins stay local. | [iCloud choices](DATA-AND-PRIVACY.md#icloud-choices) |
| Extensions and blocking | Reviewed Chrome Web Store installation, unpacked WebExtensions, signed Safari extensions, supported MV2 request filtering, and local or subscribed filter lists. Compatibility depends on WebKit and supported APIs. | [Extensions and integrations](INTEGRATIONS.md) |

## Boundaries to retain in release communication

- iCloud requires the matching signing/provisioning and deployed production schema.
  Ordinary local builds keep it unavailable. Cross-Mac convergence and Keychain
  propagation remain unverified; one-Mac service checks are not evidence of them.
  See [provisioning](ICLOUD-PROVISIONING.md) and [validation](ICLOUD-VALIDATION.md).
- Saved passwords and API keys have separate, initially unselected sync controls.
  History and extension sync data also start unselected. Download history can
  travel; downloaded bytes, paths, file grants and resume data do not.
- Cloud AI receives feature-specific metadata or extracted page text only through
  the connection selected for that feature. Private windows do not use those cloud
  features. Provider accounts, plan eligibility, billing and usage limits still apply.
- [Streaming observations](STREAMING-COMPATIBILITY.md) recorded Netflix 4K SDR and
  Dolby Vision, Spotify local music playback, and Disney+ protected video at 720p
  on one signed, notarized nightly on macOS 27.0.1. These are dated observations,
  not fresh tests of this source snapshot or a general compatibility guarantee.
- Passkeys still require Apple's managed entitlement and provisioning. Directory
  uploads remain blocked on the documented macOS 27.0.x setup. See the
  [compatibility evidence](REAL-SITE-COMPATIBILITY.md) and
  [readiness tracker](BROWSER-READINESS-TODO.md).

The website's native video and screenshots keep their recorded
[capture provenance](media/README.md); they are product illustrations, not new
validation of every current feature. Installation files remain on the
[published releases page](https://github.com/notnaki/vane/releases).
Follow [release procedures](RELEASING.md) for version selection, signing,
notarization, candidate checks and publication. Merging documentation does not
publish a release.
