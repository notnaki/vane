# Chromium session import

General **Vane → Import History & Bookmarks…** now has a separate source/destination review
with **Also copy cookies / sessions** off on every invocation. History/bookmarks keep their
existing atomic transaction; cookies are an optional, separately reported category. The Arc
importer uses the same snapshot, decryption, cookie conversion and preservation publisher.

## Supported source boundary

| Browser | Safe Storage service | Account |
| --- | --- | --- |
| Chrome | Chrome Safe Storage | Chrome |
| Chromium | Chromium Safe Storage | Chromium |
| Edge | Microsoft Edge Safe Storage | Microsoft Edge |
| Brave | Brave Safe Storage | Brave |
| Vivaldi | Vivaldi Safe Storage | Vivaldi |
| Opera | Opera Safe Storage | Opera |
| Arc | Arc Safe Storage | Arc |

These are stable-channel identities. Other channels/brands must be added explicitly with
synthetic identity coverage; there is no fallback or Keychain enumeration. Manually chosen
folders require a browser choice before sessions become available. Firefox/Safari extraction,
modern unsupported encryption and device-bound credentials remain outside this path.

The source is read-only using SQLite backup into memory, not a temporary database copy.
Supported layouts are schema 23 (legacy values) and 24 (encrypted values must carry the
matching host SHA-256 prefix). macOS `v10` uses the existing Arc PBKDF2/AES-CBC primitive.
`v11`, `v20`, damaged ciphertext, mismatching host hashes, and unknown schemas are never
interpreted as plaintext. Clear `value` rows are accepted only with an empty `encrypted_value`.

References: [Chromium schema history](https://chromium.googlesource.com/chromium/src/+/main/net/extras/sqlite/sqlite_persistent_cookie_store.cc),
[macOS v10 primitive](https://raw.githubusercontent.com/chromium/chromium/131.0.6761.0/components/os_crypt/sync/os_crypt_mac.mm),
[Chrome/Chromium identities](https://raw.githubusercontent.com/chromium/chromium/131.0.6761.0/components/os_crypt/sync/keychain_password_mac.mm).

## Publication and reporting

Cookie construction retains Secure, HttpOnly, SameSite (including unset), host-only/domain
scope, path, session lifetime and expiry. Unsupported partitioning, invalid attributes,
expired rows and Foundation lifetime normalization are rejected. Cookie values and secrets
are never logged. The general importer obtains the matching Safe Storage key only after
explicit opt-in, and only when the snapshot has supported encrypted rows.

Vane serializes cookie-import publishers, fetches current cookies immediately before each
write and skips existing name/domain/path collisions. Host-only and dotted-domain identities
are treated conservatively as collisions. It verifies the full cookie after WebKit completion;
unverified writes count as failed, never imported. A mismatching readback with the imported
value is removed from that same captured store; later site replacements are kept. Public WebKit has no atomic cookie
compare-and-set: close destination site tabs when importing to avoid concurrent site changes.
The preservation check covers existing cookies and concurrent Vane import publishers; it
cannot lock a live site's network response between WebKit calls.

Cancellation and destination/profile/private admission are rechecked before mutation and
following source/key/decryption awaits. All work remains under one `ImportOperations`
admission so quit/restore drains the actual cookie publication. Completed cookie writes stay
in place on cancellation. History and bookmarks remain one atomic category transaction.
Cookie read/schema failures do not undo a successful history/bookmark import.

## Focused validation

The suites use generated SQLite databases, injected synthetic Safe Storage secrets, injected
storage failures and disposable WebKit profile stores. They never inspect installed browser
profiles or call the real source Keychain reader. The opt-in Keychain integration test in
`ArcImportTests` remains disabled.

```sh
python3 scripts/run-native-tests.py --jobs 1 --filter 'ChromiumCookie.*Tests|ArcImportTests|ArcRoutingImportTests|BrowserDataFidelityTests|ImportWorkerTests|ProfilePersistenceTests'
.build/out/Products/Debug/vane selfcheck --pure
```

Coverage includes schema 23/24, unsupported schemas/encryption, the existing independent AES
vectors, host binding, mixed valid/rejected/failed rows, optional session review, actual general
import execution, existing cookie preservation, cancellation, destination/private revocation,
write/readback errors and attribute loss, and Arc/history/bookmark regressions. Native store
coverage creates no WebViews or windows and verifies attributes and profile/private isolation.
The wrapper retires only explicitly owned named stores after the test host exits.

Interactive alerts, permission panels, sandbox grants, account/provider sign-in compatibility,
other macOS versions and notarized builds require their own evidence. No foreground tests,
input injection, screenshots or real credentials are used by this task. Required full CI and
independent review remain parent-owned before merge. Imported cookies do not prove sign-in.

Local evidence on 2026-11-10: the focused wrapper completed 107 tests with zero failures
and one deliberately skipped Keychain fixture; its fresh retirement host removed both exact
owned backends. `selfcheck --pure` passed. Behavioral red runs were retained for unsupported
schema/encryption, publication and opt-in execution, review eligibility, malformed/overflowing
SQLite flags, Opera root detection, weakened-readback cleanup and conservative Arc reporting.
The initial broader focused baseline passed Arc but crashed when an existing import-worker
failure path accessed `Windows.current` before creating `NSApplication`; the fixture now
initializes AppKit after its isolated environment, without activation or windows. All 23
import-worker tests passed afterward. Full required CI and independent review are pending.
