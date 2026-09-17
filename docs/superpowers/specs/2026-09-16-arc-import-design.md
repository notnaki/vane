# Import from Arc — design

Date: 2026-09-16. Approved in chat by the user ("yes"; sessions included).

## Goal

One menu item, "Import from Arc…", that brings a whole Arc installation into Vane: profiles,
spaces (with their themes, pinned tabs, folders, Today tabs), each profile's favourites row,
passwords, logged-in sessions (cookies), and history + bookmarks. Re-running it is safe.

## Where Arc keeps things (verified on the user's Mac)

- `~/Library/Application Support/Arc/StorableSidebar.json` — `sidebar.containers[]`. One
  container holds `spaces`, `items`, `topAppsContainerIDs`.
  - `spaces[]`: `id`, `title`, `profile` (`{default: true}` or
    `{custom: {_0: {directoryBasename: "Profile 1", …}}}`), `containerIDs`
    (`["pinned", <pinnedContainerID>, "unpinned", <unpinnedContainerID>]`),
    `customInfo.windowTheme` (colour palettes; `primaryColorPalette.midTone {red,green,blue}`
    when present).
  - `items[]`: `id`, `parentID`, `childrenIds` (ordered), `title`, `data` = one of
    `tab {savedURL, savedTitle}`, `list {}` (a folder; `title` is its name),
    `itemContainer {containerType …}` (the roots). Order is the parent's `childrenIds`.
  - `topAppsContainerIDs`: flat list alternating profile descriptor → container id; the
    children of that container are the profile's favourites.
- `~/Library/Application Support/Arc/User Data/Local State` — `profile.info_cache`
  maps directory (`Default`, `Profile 1`, …) → `name`. Arc's default profile is `Default`.
- Per profile dir: `Login Data` (SQLite `logins`: `origin_url`, `username_value`,
  `password_value`), `Cookies` (SQLite `cookies`: `host_key`, `name`, `encrypted_value`,
  `path`, `expires_utc`, `is_secure`, `is_httponly`, `samesite`), `History`, `Bookmarks`.
- Encryption (Chromium on macOS): keychain generic password service "Arc Safe Storage"
  account "Arc" → key = PBKDF2-HMAC-SHA1(secret, salt "saltysalt", 1003 rounds, 16 bytes);
  AES-128-CBC, IV = 16 × 0x20, PKCS#7; ciphertext is the value with its `v10` prefix
  dropped. Newer Chromium cookies prepend SHA-256(host_key) (32 bytes) to the plaintext:
  strip it when the first 32 bytes equal that hash. `expires_utc` is microseconds since
  1601-01-01; 0 means session cookie.

## Mapping into Vane

- Profiles: Arc `Default` → `ProfileManager.defaultID`. Every other Arc profile → the Vane
  profile with the same name, created with `ProfileManager.shared.create(name:)` if absent.
- Spaces: for each Arc space, in its mapped profile, `createSpace(name:in:)` unless a space
  of that name already exists there (then skip the whole space — idempotent re-runs).
  Theme: Arc `midTone` → hex → `Spaces.setThemeColors([hex], on:)`; no theme → leave default.
  `pinnedTabURLs` = the pinned container's tabs in order; folders become `Pins` entries
  (`Folder` + `parent`) saved with the space's shape key (see `Folders.swift` `shapeKey`,
  `saveShape`); `tabURLs` = the unpinned container's tabs. Titles go to the space's
  sidecar (`Suspension.SpaceState.save`) as `Parked(title:)` under the tab url so rows come
  up named, not as hosts. Only `http(s)` urls; skip the rest.
- Favourites: the profile's topApps tabs appended to the profile's favourites list
  (`TabStore.defaultsKey(.favourite, profileID)`), skipping urls already there.
- Passwords: for each login with a non-empty username and password,
  `Passwords.save(host: origin host, account:, password:, profileID:)`, skipping
  (host, account) pairs already saved. Count saved / skipped / undecryptable.
- Sessions: each decrypted cookie → `HTTPCookie` → `Profiles.dataStore(for: profileID)
  .httpCookieStore.setCookie`. Skip anything that fails to decrypt or build.
- History + bookmarks: `BrowserImport.importAll(from:)` per mapped profile, using the
  existing per-profile plumbing (check how it targets a profile's Store).

## UI

File menu, beside the existing import items: "Import from Arc…". Flow:
1. `NSOpenPanel` (directory, can't create) opened at `~/Library/Application Support/Arc`;
   the sandbox only grants what the user picks, exactly as `BrowserImport.chooseAndImport`
   does. Cancel = nothing happens.
2. Parse; show one `NSAlert`: "Found 3 profiles, 3 spaces, 41 pinned tabs, 235 passwords,
   N cookies" with Import / Cancel. Mention that macOS will ask once to allow Vane to read
   Arc's Safe Storage key.
3. Import on the main actor in the order profiles → spaces → favourites → passwords →
   sessions → history/bookmarks; a toast at the end with the counts; failures inside one
   profile never abort the others.
4. Arc need not be closed: the SQLite files are copied to a temp dir before opening.

## Non-goals (v1)

Archive, Boosts, Easels, notes, per-tab scroll state, Little Arc settings, extensions.
No sync, no merge of existing Vane spaces.

## Testing

Pure, in the existing `check()` style, registered in the selfcheck table:
- Sidebar parser over a trimmed fixture JSON (3 spaces, folders, favourites, a non-http url).
- Profile mapping (default → default id; name reuse; name creation).
- Chromium decryption over a known key/IV vector (encrypt with CommonCrypto in the check,
  decrypt with the importer), including the hashed-host cookie prefix strip.
- `expires_utc` conversion.
Not automated: the real keychain prompt and the panel; build + `selfcheck --pure` must pass.
