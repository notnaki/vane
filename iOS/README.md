# Vane for iOS

A SwiftUI + WebKit browser that syncs Spaces, favourites, pinned tabs and open tabs with
Vane on the Mac. It compiles the Mac app's own sync engine (`ICloudModel`, `ICloudJournal`,
`ICloudTransport`, `ICloudRemoval`, `ICloudApplyContext`) so both apps speak one format.
Every record is kept verbatim, so fields the iOS app doesn't show go back unchanged.
Without iCloud, Settings → Import from Mac Backup… (or opening a `.vanebackup` from Files)
reads a Mac backup with the Mac's `BackupArchive` and `BackupEncryption` and turns its
Spaces, favourites, pinned tabs and folders into the same records (`MacBackup.swift`).

```sh
cd iOS && xcodegen && open Vane.xcodeproj
```

Build with Xcode 27.1 or later (iOS 27.1 SDK, iPhone Duo layout).

## Before the first App Store submission

- Register the App ID `io.github.notnaki.vane.iphone` (`.ios` was already taken) on team T7X84HN3W3 with iCloud (CloudKit)
  and Push Notifications, and assign it the existing container `iCloud.io.github.notnaki.vane`.
- Create the app in App Store Connect. Privacy Policy URL: the repository's `PRIVACY.md`.
  App Privacy: "Data Not Collected". Age rating: answer "Unrestricted Web Access" (rates 18+).
- Product → Archive, then Distribute App → App Store Connect.
- Being offered as the default browser needs Apple's separate
  `com.apple.developer.web-browser` entitlement request; the app works without it.
