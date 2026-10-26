# Extension validation and compatibility

[Documentation index](README.md) · [Extension user guide](INTEGRATIONS.md#extensions)

This record separates implementation, automated regressions, metadata parsing, and assembled-app observations. A successful manifest parse does not establish that background code, website injection, blocking, autofill, or every declared API works. No Chrome Web Store installation or full Chromium compatibility is claimed.

## Focused regression scope

Run from the repository root:

```sh
swift test --filter 'Extension.*Tests'
./.build/debug/vane selfcheck --pure
```

| Suite | Behavior covered |
| --- | --- |
| `ExtensionConsentTests`, `ExtensionAccessLifecycleTests` | Installation cancellation, required/optional access, missing/corrupt approval, permission/site expansion, removal/profile deletion during review, and private-profile rejection. |
| `ExtensionCodeStoreTests` | Independent profile snapshots, regular-file copying, symlink/FIFO/oversized-file rejection, cleanup, and corrupt or redirected metadata storage. |
| `ExtensionManagedCodeTests`, `ExtensionManagementTests` | Accepted code after source loss/edits, failed/declined updates, staged-byte isolation, disabled updates, identity retention, source relocation, removal, pins, resource validation, owned options cleanup, and sanitized diagnostics. |
| `ExtensionCompatibilityTests` | MV2/MV3 background messaging, local storage and runtime/origin identity restoration, reinstall isolation, and content-script origin/profile/private isolation. |
| `ExtensionRuntimePermissionTests` | Permission/match-pattern/URL requests, rejection, pending-request removal, revocation, expiry, session restoration, and unavailable native-host capabilities. |
| `ExtensionManagerModelTests`, `ExtensionManagerPaletteTests` | Search folding, counted filters, inactive metadata, selection changes, and command-palette profile ownership. |
| `ExtensionLifecycleTests` | Public keyboard command matching and routing guards, collisions, tab movement/selection/window closure, explicit rejection of hidden-row selection, adapter identity, menu dispatch, and options-window lifecycle. |

Local validation on 2026-10-12, macOS **27.0.1 (26A434)** / **Xcode 27.0 (27A266a)**:

- `swift test --filter 'Extension|WebsiteDataWebKitTests'`: **88 passed**, including manager Command-F ownership, hidden-row selection rejection, and all five website-data checks. The selection regression first failed against the previous implementation, then passed with the explicit error.
- `swift test` after integrating current main: **1162 executed, 17 skipped, four assertions failed** in `WebsiteDataWebKitTests.testDeletingOnlyCookiesPreservesLocalStorageAndPrivateStore`. Earlier broad runs (1108 tests before main integration) failed the same four assertions. The missing storage record was observed before deletion. The same five-test suite passed independently and with the extension suites; no root cause is established. All extension checks passed in the broad runs. These broad local runs are **not passes**.
- `./.build/debug/vane selfcheck --pure`: **PASS (pure)**.
- `./make-app.sh debug`: signed sandboxed debug bundle assembled successfully; ad-hoc signature verified with `codesign --verify --deep --strict`.
- `git diff --check`: passed.

The final PR records its reviewed head and CI outcome separately. The integrated broad run preceded only the final hidden-row selection guard; the focused run above includes that fix.

## Signed Safari app fixtures — 2026-10-24

On macOS **27.0.1 (26A434)** / **Xcode 27.0 (27A266a)**, an isolated Apple
Development-signed app containing a Safari web extension passed **12 tests**. These
exercise the production app-bundle installer, consent rejection and reviewed updates,
verified identity, modified/ad-hoc signature rejection, duplicate installs, missing-app
restore, metadata recovery, accepted-installation restart with persistent storage, profile storage
separation, removal during asynchronous
refresh, and reinstall without inheriting `storage.local`, `storage.sync`, or
`storage.session`. The external-message test opens a real Vane tab with a local fixture
page at an allowed HTTPS origin and verifies its nonce reply through
`browser.runtime.sendMessage` addressed to the genuine signed Safari runtime ID.
No provider account, Proton sign-in, native messaging host, or upstream extension
package was exercised by this fixture.

The separate metadata/signature/store batch passed **8 tests**, including resource-seal
verification and a read-only signature check against an installed, unmodified Mac App
Store app. Mac App Store signatures use Apple's store certificate; developer signatures
bind the Team ID to the signing certificate's organization unit. The store-certificate
alternative follows [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
This signature check does not establish runtime compatibility of a Mac App Store Safari
extension. The existing folder-extension regressions plus the signed restart check passed
**82 tests**. The pure self-check also passed.

Signed fixture tests skip unless an existing Apple signing identity and its verified
Team ID are explicitly supplied. They create and remove disposable local bundles and
never execute their native fixture binaries:

```sh
VANE_TEST_SIGNING_IDENTITY='<existing Apple signing identity>' \
VANE_TEST_SIGNING_TEAM='<verified Team ID>' \
swift test --filter 'SafariAppExtensionTests|SafariAppSignatureTests|SafariAppExtensionMetadataTests'
```

The optional read-only Mac App Store check additionally requires
`VANE_TEST_MAC_APP_STORE_BUNDLE` and `VANE_TEST_MAC_APP_STORE_TEAM`. It never launches,
modifies, copies, or re-signs the selected installed app. No signing identity or account
credentials are included in the repository.

## Official third-party packages — 2026-10-12

Packages came directly from the projects’ GitHub release assets. Archives were extracted into a temporary fixture directory using bounded Python ZIP handling: absolute/traversal/ambiguous duplicate paths, symlinks/special files, encrypted entries, excessive entries, and excessive expanded sizes were rejected. Each archive SHA-256 matched GitHub’s release-asset digest. This preparation tool does not add ZIP import to Vane. No credentials or accounts were used; parser verification did not execute extension code.

| Fixture | Extension version | Manifest | Official release and exact asset |
| --- | --- | --- | --- |
| `darkreader-mv2` | 4.9.133 | MV2 | [v4.9.133](https://github.com/darkreader/darkreader/releases/tag/v4.9.133) · [darkreader-chrome.zip](https://github.com/darkreader/darkreader/releases/download/v4.9.133/darkreader-chrome.zip) |
| `darkreader-mv3` | 4.9.133 | MV3 | [v4.9.133](https://github.com/darkreader/darkreader/releases/tag/v4.9.133) · [darkreader-chrome-mv3.zip](https://github.com/darkreader/darkreader/releases/download/v4.9.133/darkreader-chrome-mv3.zip) |
| `ubolite-chromium` | 2026.1006.1931 | MV3 | [2026.1006.1931](https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.1006.1931) · [uBOLite_2026.1006.1931.chromium.zip](https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1006.1931/uBOLite_2026.1006.1931.chromium.zip) |
| `ubolite-safari` | 2026.1006.1931 | MV3 | [2026.1006.1931](https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.1006.1931) · [uBOLite_2026.1006.1931.safari.zip](https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1006.1931/uBOLite_2026.1006.1931.safari.zip) |
| `bitwarden-chromium` | 2026.9.3 | MV3 | [browser-v2026.9.3](https://github.com/bitwarden/clients/releases/tag/browser-v2026.9.3) · [dist-chrome-2026.9.3.zip](https://github.com/bitwarden/clients/releases/download/browser-v2026.9.3/dist-chrome-2026.9.3.zip) |
| `bitwarden-firefox` | 2026.9.3 | MV2 | [browser-v2026.9.3](https://github.com/bitwarden/clients/releases/tag/browser-v2026.9.3) · [dist-firefox-2026.9.3.zip](https://github.com/bitwarden/clients/releases/download/browser-v2026.9.3/dist-firefox-2026.9.3.zip) |

Exact upstream commits:

- Dark Reader `v4.9.133`: `92637d8c3fbb210853c005e3f25dbbec46dd21fc`.
- uBO Lite `2026.1006.1931`: `9379e3387c6f615e695add23c2325c8705faca83`.
- Bitwarden `browser-v2026.9.3`: `8246ae9c9a484a0a69f8b27203034555fb872523`.

| Fixture | Archive SHA-256 |
| --- | --- |
| `darkreader-mv2` | `3515b14f96bee900be6f606c1d2b4e0272440261a46c2b14f77917b25e89890e` |
| `darkreader-mv3` | `a5a1a9c78d377fafd8c9190ce9d57b96f89bc95d21f077888601e4c445b20ebf` |
| `ubolite-chromium` | `1670f92590f5ad5b20f02d0a75e144572567b4ba979b3dc3204c41f651206fe7` |
| `ubolite-safari` | `2dd32e4d84a4666e7864f527f037f0191ee0175ecfbd95ab88cfefca0e273f3f` |
| `bitwarden-chromium` | `7185bad74d44b1d7e81b3dc9858a206bf9debff272d7e5bfc7f56a4b9d942ca0` |
| `bitwarden-firefox` | `bef7aaa96667f1e33866e917d18c0cdaff7a3bc2776611df1a924249deef252b` |

### Parser-only evidence

On macOS **27.0.1 (26A434)** with **Xcode 27.0 (27A266a)**, the public `WKWebExtension(resourceBaseURL:)` constructor accepted all six unpacked packages and returned zero `errors`. No `WKWebExtensionContext` was created or loaded, so this did not execute their background code or content scripts.

The table compares manifest API permission strings with the union of WebKit’s `requestedPermissions` and `optionalPermissions`. Omission is a parser observation for this environment, not a cross-version statement or a complete API audit. Website patterns are not counted as API permissions.

| Package | Declared API permissions omitted by this WebKit parser |
| --- | --- |
| `darkreader-mv2` | `fontSettings` |
| `darkreader-mv3` | `fontSettings` |
| `ubolite-chromium` | `offscreen`, `userScripts` |
| `ubolite-safari` | None |
| `bitwarden-chromium` | `clipboardRead`, `idle`, `offscreen`, `privacy`, `sidePanel`, `webRequestAuthProvider` |
| `bitwarden-firefox` | `clipboardRead`, `idle`, `privacy`, `webRequestBlocking` |

Current WebKit recognizes `notifications` in these Bitwarden manifests even though the installed SDK has no named permission constant for it. `nativeMessaging` is recognized too, but Vane explicitly marks its send/connect APIs unavailable because Vane has no native-host bridge. Parser recognition alone therefore does not imply usable integration.

For reproduction, instantiate each downloaded folder without loading a context:

```swift
let extensionMetadata = try await WKWebExtension(resourceBaseURL: folder)
print(extensionMetadata.errors)
print(extensionMetadata.requestedPermissions.map(\.rawValue).sorted())
print(extensionMetadata.optionalPermissions.map(\.rawValue).sorted())
```

### Assembled-app evidence

The assembled checks used Vane **0.0.29 (429)**, a separately named and signed sandboxed test bundle with a unique bundle ID and an isolated `VANE_DATA_DIR` under Downloads. The initial manager/runtime UI binary SHA-256 was `3bec0ced48b0ed5eaca304ebc440394ac37b2c582baaf37f9b85bee70af01c36`. The final integrated UI binary SHA-256 was `4f7846d50592fff4ace13f7c3cf6365585c9addbea2597a952672dbbd01ed6eb`; its shared native window styling, narrow details, Command-F search, no-results feedback, compatibility text, and retained toolbar pin were checked again. No regular Vane profile or credentials were used.

| Workflow | Observed evidence / scope |
| --- | --- |
| Open manager from Extensions, Settings, and command palette | Observed dedicated retained “Extensions — Personal” window from all three entry points; originating-profile palette ownership also has a regression check. |
| Adaptive manager layout | Visually inspected native dark appearance at 980-point wide and approximately 757-point narrow widths; narrow detail view and Escape back to list worked. Light appearance and minimum-width inspection remain unverified. |
| Search, filters, enable/disable, pin | Search no-results and clear-search feedback observed. Counts changed from three enabled to two enabled/one disabled and back. Saved pin remained while disabled; re-enabled extension appeared in browser toolbar and its pin survived a fresh process. After fixing browser Find interception, native Command-F from narrow details returned to the list and focused manager search; typing then displayed no results. |
| Accessibility and motion | Accessibility tree exposes profile, search, counted filters, enable switches, back navigation, and details/actions. Escape tested through native keyboard input. VoiceOver speech/navigation and system Reduce Motion were not manually exercised. Motion uses Vane’s existing Reduce Motion/Battery Saver policy. |
| Folder installation/review | Native folder picker selected the synthetic MV3 fixture; a review showed exact capabilities and website access before acceptance. Drag/drop and manual cancel/update/source relocation remain unverified in assembled UI; production staging/update failure, review cancellation, relocation, and identity/storage preservation have focused tests. |
| Access and diagnostics | Separate required, optional, and temporary access sections inspected in the real manager. Runtime grants/revocation/expiry and diagnostic redaction are automated regressions; copied clipboard contents were not manually inspected. |
| Dark Reader **4.9.133 MV3** | Unmodified release reviewed and installed. Controlled known-white loopback page acquired Dark Reader styles and changed computed background. Real anchored action popup and native options page exposed rendered UI. Existing UI message API changed brightness to 110; a subsequent process restored the same setting and WebKit identity. MV2 is parser-only; its default commands were not manually exercised. |
| uBO Lite **2026.1006.1931 Safari MV3** | Unmodified release reviewed and installed. Real popup and dashboard rendered. WebKit reported enabled `easylist`, `easyprivacy`, and `ublock-filters`. A temporary harness dynamic rule through uBOL’s context blocked a controlled script request while an allowed control executed; the server observed zero blocked-endpoint requests. Removed only that rule. This verifies DNR integration, not upstream real-site or cosmetic filter coverage. Chromium is parser-only. |
| Bitwarden **2026.9.3 Firefox MV2** | Review attempted; activation failed during background initialization (`this.device.toString` on null). No installation was activated. Root-cause investigation is below. Chromium is parser-only. |
| Bitwarden vault/autofill/sync/passkeys/biometrics/native desktop integration | **Unverified/unavailable**; no real account or credential data used. |
| Synthetic **Vane Runtime Smoke 1.0.0 MV3** | Installed through manager review. Native Command-Shift-Y through the normal app event monitor changed the example.com page title to “Extension command verified”. Native webpage right-click included “Verify Vane Extension Page Menu”; activating it changed the title to “Extension menu verified”. Pinned toolbar action opened its rendered popup. No real extension compatibility is inferred from this synthetic fixture. |
| Synthetic assembled harness fixture **1.0 MV3** | Real anchored popup and native options page worked. Routed NSEvent command dispatch succeeded on the first run; later runs timed out obtaining browser key focus, so those later command attempts are unavailable. The normal-app keyboard check above independently verified the main monitor path. |
| Cross-profile/private/lifecycle | Automated content-script, controller/origin/storage, private restriction, command routing, moved/selected/closed tab, window closure, and stale-options checks passed. In a real private window, installation was disabled and the manager showed the Private profile with an explicit extension restriction. Manual multiple-regular-profile UI checks remain unverified. |
| Test app ownership | Every launch recorded exact bundle/executable, PID, and start time. All three harness and three UI processes exited; each UI process used its own “Quit” confirmation. The final tracked PID 55048 exited normally, and the regular `/Applications/Vane.app` instance remained running with its original start time. |

The opt-in `extensioncheck` CLI runs only from a signed sandboxed `.app` with an isolated Downloads data directory. First use requires that directory contain only `fixtures` (and optionally `.DS_Store`), with `darkreader-mv3`, `ubolite-safari`, and `bitwarden-firefox` unpacked from the exact assets above. It mints a directory-bound marker; reruns require that marker. It explicitly accepts these known fixtures, denies extra runtime prompts, serves only bounded loopback fixtures, records outcomes, and retains accepted installs/settings for a fresh-process check. It never uses a normal profile or real credentials. Run it twice with the same isolated directory to verify Dark Reader’s saved option and identity. The first restart exposed an incorrect white-baseline harness assumption because restored Dark Reader had already styled the page; the harness now explicitly checks for restored styles. That was corrected in the harness, not hidden as an extension failure.

Prefer the uBO Lite Safari package for WebKit testing: its declared APIs are recognized in this parser check. The Chromium variant requests `offscreen` and `userScripts`. The Bitwarden Firefox package avoids Chromium `offscreen`/`sidePanel` requirements, but still declares APIs omitted by WebKit. A popup opening is not proof of blocking or password autofill. Verify actual content/style changes or a known filter match before recording those as passed.

### Password-manager startup investigation

The unmodified Bitwarden **2026.9.3 Firefox MV2** package was reviewed and attempted in the signed sandboxed app. Background initialization failed with `TypeError: null is not an object (evaluating 'this.device.toString')` at `background.js:1:740229`; Vane retained no activated installation. No login, vault, or credential data was used. This is a failed compatibility result, not a working password-manager claim.

At the exact release commit, [Bitwarden’s browser detector](https://github.com/bitwarden/clients/blob/8246ae9c9a484a0a69f8b27203034555fb872523/apps/browser/src/platform/services/platform-utils/browser-platform-utils.service.ts) recognizes specific Firefox, Chromium-family, DuckDuckGo, and Safari tokens, then returns a null device for an unrecognized browser. The startup client converts that result to a string. The recorded run used bare WebKit identity in extension pages, unlike Vane’s Safari identity in ordinary tabs.

Vane configures extension web views with the selected user agent. The controller’s [basis web-view configuration](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller/configuration-swift.class/webviewconfiguration) supplies the default Safari suffix. Full custom identities use a guarded WebKit webpage preference; a guarded creation callback also sets `customUserAgent` on the actual background view before WebKit loads its content. Existing tracked views receive the public setter on Develop changes without replacing controllers or changing grants/storage. If the full-identity preference is unavailable, Vane retains its default Safari view configuration and discloses that custom extension-view configuration is unavailable.

This configuration does not establish reliable MV3 worker identity. In the [2026-10-26 signed normal-app comparison](https://github.com/notnaki/vane/actions/runs/40361071454), a fresh Safari MV3 worker reported bare WebKit at startup and on reply, while its bound registering document, popup and native view used the selected Safari UA. The matched background-owner process loaded the staged Safari27 engine; identity/image inspection and exact post-exit store retirement passed. The original UA comparison failed and remains unresolved.

Apple documents [`customUserAgent`](https://developer.apple.com/documentation/webkit/wkwebview/customuseragent) for the web view, without an explicit extension-worker propagation guarantee. WebKit’s [regular-service-worker override test](https://github.com/WebKit/WebKit/blob/9296bd1b87efef73a9dd2883a91e594d11379cca/Tools/TestWebKitAPI/Tests/WebKit/WKWebView/ServiceWorkerBasic.mm#L644-L702) expects the initial override, then deliberately expects an existing worker to retain that original UA when a later page uses a different one. That retention case does not explain the fresh extension-worker mismatch. Neither intended bare-UA behavior nor a violated public extension-worker contract has been established.

The synthetic `ExtensionUserAgentTests` check background/worker and popup startup identity, live MV2 background/popup changes, popup recreation, host restoration, and unchanged access. The MV3 selection sequence removes and reinstalls the fixture between selections; it tests fresh-worker startup, not live UA changes in an existing worker. These assertions remain intact, and a finite passing run does not clear the signed-app failure. A synthetic UA mismatch alone does not demonstrate functional failure in a real MV3 extension.

These checks do not revalidate the historical Bitwarden package or the exact Safari2026.10.0 MV2 popup case in [#484](https://github.com/notnaki/vane/issues/484), and do not establish authenticated workflows. [#513](https://github.com/notnaki/vane/issues/513) tracks the separate MV3 identity discrepancy. Selecting Safari branches also introduces [Safari host integration](https://github.com/bitwarden/clients/blob/8246ae9c9a484a0a69f8b27203034555fb872523/apps/browser/src/browser/safariApp.ts), including native messaging that Vane does not implement. Reviewed upstream packages are not patched. Chromium Bitwarden remains parser-only evidence.

## ZIP import decision

ZIP import is deferred. [Apple’s public initializer](https://developer.apple.com/documentation/webkit/wkwebextension/init(resourcebaseurl:)) accepts a directory or ZIP containing `manifest.json` and reports invalid manifests/archives. Its documented contract does not establish Vane’s required extraction bounds or path/symlink policy. Use Finder to extract the official archive, then select or drop the folder containing `manifest.json`. There is no new archive dependency.

A future importer must extract into profile-owned staging before review, reject absolute/traversal paths, symlinks/special files, conflicting or case-ambiguous entries and unsupported encrypted archives, enforce entry/per-file/aggregate bounds while streaming, check integrity, require one unambiguous manifest root, and validate resources before activation. Failed/cancelled import must clean staging without changing accepted code. Passing an arbitrary ZIP straight to WebKit does not establish these safeguards.

## Native messaging investigation

Native-host execution is deferred. Public macOS 15.4+ WebKit hooks include [one-time messages](https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:sendmessage:toapplicationwithidentifier:for:replyhandler:)) and [persistent message ports](https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:connectusing:for:completionhandler:)). Their default handling can forward to an app extension’s handler when loaded from that bundle; unpacked resources have no such handler. Ports must be retained while connected. The missing piece is Vane’s host integration, rather than an absence of public WebKit hooks.

[Chrome’s native messaging design](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) registers a host manifest with an absolute executable path on macOS and exact allowed origins. A separate process exchanges UTF-8 JSON framed with native-order 32-bit lengths; documented limits are 1 MiB from host and 64 MiB to host. Persistent ports and one-time messages have different process lifetimes.

Before adding execution, Vane needs its own host registration/discovery and trusted identity mapping; explicit per-extension/per-host consent and revocation; profile/private restrictions; validated executable/manifest paths and signing/sandbox/distribution policy; process launch without shell evaluation; framing, JSON, size, backpressure and timeout bounds; and port/process teardown on disable, removal, profile deletion, and quit. Diagnostics must exclude message payloads and credentials. An unpacked manifest key is not proof that its code is an allowlisted store extension. Reusing another browser’s registry or pretending Vane’s UUID origin is a production Chrome origin would bypass that trust design.

[Bitwarden’s upstream integration guide](https://contributing.bitwarden.com/getting-started/clients/browser/biometric/) describes its desktop proxy and host manifests, which normally allow production extension IDs; development IDs require explicit configuration. Its Safari bundle integration differs from an unpacked Chromium package. Vane’s public hooks and stable UUID storage identity do not automatically enable Bitwarden desktop biometric integration.
