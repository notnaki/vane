# Vane documentation

New to Vane? Start with the [project README](../README.md). These guides follow
`main`, so the latest release may be a little behind. For a visual tour, see the
website's [field guide](https://vane.so/docs.html).

## Using Vane

| Guide | Covers |
| --- | --- |
| [Everyday browsing](BROWSING.md) | Tabs, folders, Spaces, windows, search, shortcuts, Library, downloads, and media. |
| [Reading and customization](FEATURES.md) | Reader, saved articles, Easels, capture, Boosts, Space templates, themes, and Battery Saver. |
| [Profiles, data, and privacy](DATA-AND-PRIVACY.md) | Passwords, passkeys, imports, exports, backups, website data, iCloud, and private browsing. |
| [Extensions and integrations](INTEGRATIONS.md) | Extensions, content blocking, site permissions, AI connections, and GitHub Live Folders. |
| [Privacy policy](../PRIVACY.md) | What Vane stores, what it sends, and how to control it. |

When something goes wrong:

- A page came back paused after a crash: [crash recovery](CRASH-RECOVERY.md).
- You're worried about losing form text: [draft protection](DRAFT-PROTECTION.md).
- A download stopped: [downloads](DOWNLOAD-RELIABILITY.md#behavior-and-limits).
- A site doesn't work: [site compatibility](REAL-SITE-COMPATIBILITY.md).

## Reference

Detailed records of how features behave, how they were tested, and where they stop.

| Topic | Document |
| --- | --- |
| Passwords and Keychain | [Password manager](PASSWORD-MANAGER.md) |
| Extensions | [Extension validation](EXTENSION-VALIDATION.md), [Manifest V2](MANIFEST-V2-COMPATIBILITY.md), [worker identity](EXTENSION-WORKER-IDENTITY.md) |
| Sites and streaming | [Site compatibility](REAL-SITE-COMPATIBILITY.md), [streaming](STREAMING-COMPATIBILITY.md) |
| Permissions | [Site permissions](SITE-PERMISSIONS.md) |
| iCloud | [Provisioning](ICLOUD-PROVISIONING.md), [validation](ICLOUD-VALIDATION.md) |
| Security | [Security review](SECURITY-AUDIT.md), [security policy](../SECURITY.md) |
| Recovery | [Crash recovery](CRASH-RECOVERY.md), [draft protection](DRAFT-PROTECTION.md), [downloads](DOWNLOAD-RELIABILITY.md) |

## Working on Vane

- [Contributing](../CONTRIBUTING.md): your first change and pull request.
- [Development](DEVELOPMENT.md): setup, CLI, tests, and project structure.
- [Releasing](RELEASING.md): versions, signing, notarization, and publishing.
- [Website](WEBSITE.md): the `website` branch, search, and shared-link previews.
- [App icons](../AppIcons/README.md).

Older implementation plans, specs, and one-off investigations were removed from
the tree; they're still in the Git history.
