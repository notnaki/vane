# Extension validation and compatibility

[Documentation index](README.md) · [Extension user guide](INTEGRATIONS.md#extensions)

This record separates implementation, automated regressions, metadata parsing, and assembled-app observations. A successful manifest parse does not establish that background code, website injection, blocking, autofill, or every declared API works. No Chrome Web Store installation or full Chromium compatibility is claimed.

## Page control for Claude in Chrome (`chrome.debugger`) — 2026-11-23

Vane now answers the part of `chrome.debugger` that the official **Claude** extension uses to act on pages, and `runtime.getContexts`. With the unmodified extension installed and signed out, calls made through its own side panel's `chrome.debugger` attached to a page, evaluated script, took a screenshot, clicked a button and typed into a field. **No Claude account was used, so Claude itself never drove a page:** its agent loop, permission prompts and tools past the Log in screen are untested.

**Build and package.** macOS 27.0.1 (26A434), debug test host built from this change on the side-panel branch at `d7a17c8d`, isolated temporary `VANE_DATA_DIR`, fresh profile. CRX from Google's public update endpoint, now version **1.0.109** (SHA-256 `036df34f2afb9647f42903300a381d1004b00b5a0c4db1350d5e8e8b8297a190`), unpacked without changes.

**What Claude's code calls** (read from the package): `debugger.attach`, `detach`, `sendCommand`, `getTargets`, `onEvent`, `onDetach`, with these protocol methods and events.

| Used by Claude | In Vane |
| --- | --- |
| `Runtime.evaluate` (its `javascript_tool`: `replMode`, `awaitPromise`, `returnByValue`, `timeout`) | Emulated. |
| `Page.captureScreenshot` (`jpeg`, `quality`, optional `clip` with `scale`) | Emulated. |
| `Input.dispatchMouseEvent` (move, press, release, wheel), `Input.dispatchKeyEvent`, `Input.insertText` | Emulated with trusted events, for the tab on screen. |
| `Page.getFrameTree`, `Page.bringToFront` | Emulated (main frame). |
| `Page.enable`, `Runtime.enable`, `Network.enable`/`disable`, `Network.setBypassServiceWorker`, `Emulation.setFocusEmulationEnabled`, `Page.startScreencast`/`stopScreencast`, `Input.cancelDragging` | Accepted and ignored. |
| `Runtime.consoleAPICalled`, `Runtime.exceptionThrown`, `Network.requestWillBeSent`/`responseReceived`/`loadingFailed` | **Not sent.** Claude's console and network readers will be empty. |
| `Page.javascriptDialogOpening`/`Closed`, `Page.handleJavaScriptDialog` | **Not sent; the command fails.** Vane shows its own dialog and Claude cannot answer it. |
| `Page.frameNavigated`, `Page.frameStartedNavigating` | **Not sent.** Claude also follows navigation through `webNavigation`, which WebKit has. |
| `runtime.getContexts` | Lists the background and open side panels. Claude's own check (`documentUrls: [location.href]`, every result a `SIDE_PANEL`) passes. |
| `tabGroups`, `tabs.group`/`ungroup` | Still absent, on purpose. Claude creates, renames, recolours and removes groups on its own; mapped to Vane's folders that would let an extension create and delete folders in the user's sidebar, which needs a design decision rather than a stand-in. |
| `identity`, `notifications`, `offscreen`, `downloads`, `favicon`, `runtime.connectNative` | Unchanged from the section below. |

**Observed** in the signed-out run, each call made from Claude's side panel page in Chrome's callback style:

| Step | Result |
| --- | --- |
| Install | The review lists the debugger capability. Installed and loaded; panel shows **Log in**. |
| `getContexts` | `[["SIDE_PANEL", -1, true]]`: one side panel whose `documentUrl` is the panel's address. |
| `attach`, `getTargets` | Attached; the tab reports `attached: true`; the pill “Claude is controlling this tab · Stop” appears. |
| Claude's attach sequence | `Page.enable`, `Runtime.enable`, `Network.enable`, `Emulation.setFocusEmulationEnabled`, `Page.stopScreencast`, `Network.setBypassServiceWorker`, `Input.cancelDragging` each returned `{}`. `Accessibility.getFullAXTree` failed with `-32601`. |
| `Runtime.evaluate` | Claude's wrapper shape (origin guard, labelled block, top-level `await`) returned `"Driven page / 9"`. |
| `Page.captureScreenshot` | JPEG, 1180×1404 pixels for a 590×702-point page at 2×. |
| Click and type | The button's `click` and the field's `keydown` events were trusted; the field read “Hi from Claude’s API ✓”. |
| Stop | Session ended; the next command failed with “Debugger is not attached to the tab with id: 90.”, the message Claude re-attaches on. |

One new error appeared in this version's worker and is not caused by this change: `TypeError: undefined is not an object (evaluating 'chrome.alarms.create(…).catch')`. WebKit's `alarms.create` returns nothing where Chrome returns a promise. The extension still starts and opens its panel. Vane cannot replace a method WebKit defines.

**Not tested:** signing in; Claude's own tool calls; real sites; strict-CSP sites; background tabs (input is refused there, which Claude's flows for hidden tabs will meet); the ⌘E toggle end to end; an assembled signed app. The window snapshots show the page area blank because `screencapture` does not composite WebKit's content for the accessory test host; `captureScreenshot.jpg` is the page as the protocol returned it.

Automated coverage: `ExtensionDebuggerTests` loads a synthetic MV3 extension with `debugger` and host access to `127.0.0.1` only, and no `tabs` permission. From an extension page and from its worker it attaches, evaluates (values, promises, top-level `await`, errors, a syntax error, a timeout), captures a PNG and a clipped scaled JPEG and checks their pixel sizes, clicks a button, types, edits with arrow, Backspace and ⌘A, scrolls with the wheel, and checks that every event was trusted. It also covers protocol errors for unsupported commands, `runtime.lastError` in callback style, refusal on a host without access, the pill's Stop and tab close reaching `onDetach` in both contexts, `getContexts`, an extension that lists `debugger` only as optional, and the bridge URL of another origin. No test moves the pointer. Evidence: `~/.cache/vane-task-evidence/chrome-debugger-2026-11-23/` (`probe.txt`, `indicator-light.png`, `indicator-dark.png`, `captureScreenshot.jpg`, the probe's source and the CRX).

## Arc extensions from the Chrome Web Store — 2026-11-23

Five Chrome Web Store extensions one user relied on in Arc, checked through Vane's own store installer: download from Google's update endpoint, CRX signature check, review, and activation. No account was used anywhere. Nothing was signed in to.

**Build.** macOS **27.0.1 (26A434)**. Vane `main` at `fe03b5f4` plus this change, debug configuration, assembled by `./make-app.sh debug`, re-signed ad hoc with Vane's sandbox entitlements under its own bundle identifier. Each extension ran in its own new `VANE_DATA_DIR` under Downloads. A second build of PR [#775](https://github.com/notnaki/vane/pull/775) at `3dca144d` plus this change measured what #775 adds.

**Harness.** `extensioncheck --store <ID>[,URL[,CSS selector]]` installs a store package (or a folder under `fixtures/`) instead of the bundled fixtures. It records the context errors, opens the real action popup and reports its text, then loads the URL (a path starting with `/` is the loopback server) and reports WebKit's injected-content answer, page references to the extension's origin, and how many elements match the selector. `/ad-check` loads `/88/tag.min.js`, a generic path rule in AdBlock's enabled EasyList ruleset. Content scripts run in an isolated world, so the selector (the extension's own element IDs or classes) is the evidence that their UI appeared. The Google Docs page was the public, view-only [Chromium design doc template](https://docs.google.com/document/d/14YBYKgk-uSfjfwpKFlp_omgUq5hwMVazy_M965s_1KA/edit).

| Extension | Store ID | Version | CRX SHA-256 |
| --- | --- | --- | --- |
| GPTZero: AI Detection & Writing Replay | `kgobeoibakoahbfnlficpmibdbkdchap` | 2026.11.6 | `3aad788684fb14d49a8c61783d93cc70b6e780d84cac2a9644a1169bdcf028f2` |
| Revision History: Writing Process Visibility for Google Docs & Slides | `dlepebghjlnddgihakmnpoiifjjpmomh` | 1.14.1 | `9759915508ad2466bc40578dbd28002792ef88d2b6ec8cfbf8b90f4e57ce605e` |
| AI Content Detector - Copyleaks | `gplcmncpklkdjiccbknjjkoidpgkcakd` | 5.1.0 | `34e9fbd34fd8447a5d40694b7f1b567c64973422e9f4028658f4868ebec19668` |
| AdBlock — block ads across the web | `gighmmpiobklfepjocnamgkkbiglidom` | 6.54.0 | `01a03a8d78c16c2fabf7640fae8b06fe22789b41e0d901cf9bbe326673ef109a` |
| Humanizer Helper | not found | — | — |

**Fixed in Vane.**

- **Partly unsupported `externally_connectable` no longer blocks installation.** Revision History was refused with “Empty or invalid `externally_connectable` manifest entry”. WebKit [skips each pattern it does not support and keeps the rest](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp) (here `https://*.vercel.app/*` or `https://localhost:3000/*`), then reports this error; Chrome ignores such patterns too. Vane now treats it as a limitation shown in the review: only pages matching the skipped patterns cannot message the extension.
- **Large extensions fit.** AdBlock unpacks to 330 MB, over the old 256 MB limit, and failed with an unreadable `vane.UpdateArchive.Failure error 1`. The limit is now 512 MB, which matches the 128 MB CRX limit at typical ruleset compression. Resources of 1 MB or more are memory-mapped from the accepted copy instead of read into memory, because MV3 workers keep the whole snapshot for the extension's lifetime. Archive failures now say what went wrong.

**Results.**

| Extension | Verdict | Observed |
| --- | --- | --- |
| Revision History 1.14.1 | **Works partly** | Installs (with this change). The popup shows its Log in / Sign up page. On the view-only Doc its content script added `div#revision-history-root.revision-history-component`, visible. The background and content pages reported no script errors. Sign-in and the writing replay need an account and were not tested. Its manifest's `oauth2` (Chrome identity) is unavailable; whether its “Sign up with Google” relies on it was not established. |
| GPTZero 2026.11.6 | **Doesn't work on `main`**; works partly with #775 | On `main` its background fails to load (`WKWebExtensionContextErrorDomain:6`). Its shared chunk reads `runtime.OnInstalledReason.INSTALL` at module top level, and system WebKit has no `runtime.OnInstalledReason` (a probe extension read `undefined` in an extension page). With #775, which adds that enum to workers and extension pages, it installs, its background loads and its popup shows “Log in to start scanning”. Its content scripts still fail: every one throws `undefined is not an object (evaluating '….runtime.OnInstalledReason.INSTALL')`. WebKit exposes this enum only in the main world ([`MainWorldOnly`](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/Extensions/Interfaces/WebExtensionAPIRuntime.idl)) and #775 does not reach content scripts, so no GPTZero element appeared in the Doc. WebKit's `cookies.onChanged` also passes no change details, so GPTZero's sign-in cookie listener throws on `e.cookie`. |
| Copyleaks 5.1.0 | **Doesn't work** | The background fails to load on `main` and with #775. Its worker calls `chrome.identity.getRedirectURL()` and `chrome.sidePanel.setPanelBehavior()` at top level. WebKit has neither namespace. With #775 a diagnostic copy (worker wrapped in `importScripts` to catch the exception) still threw `chrome.identity.getRedirectURL is not a function`, so #775's `identity` stand-in does not cover this call. Chrome's `getRedirectURL` is synchronous and returns `https://<id>.chromiumapp.org/`. Sign-in uses `identity.launchWebAuthFlow`, which Vane does not provide, so scans would stay unavailable even after the background loads. The content script loads on example.com (it attached one shadow root). |
| AdBlock 6.54.0 | **Doesn't work** | Installs with this change; the background then fails to load on `main` and with #775. Diagnostic copies found a chain of Chromium-only members that its worker uses at top level: `webRequest.ResourceType` (only the DNR enum is in #775; WebKit refuses `webtransport` and `webbundle` in listener filters, so the values must match WebKit), `scripting.ExecutionWorld`, the `idle` and `management` namespaces (declared; WebKit does not recognize them), and `webNavigation.onCreatedNavigationTarget`. With stand-ins for all but the last its worker ran to the end, but the rule path on `/ad-check` was still requested and executed, so blocking is unverified. [uBO Lite](#password-manager-unlock-and-autofill--2026-11-21) blocks requests in Vane and is the working alternative. |
| Humanizer Helper | **Not identified** | No Chrome Web Store listing has this name (store search and web search, 2026-11-23). The closest match is “Humanize Helper”, a GitHub project loaded unpacked beside a Windows desktop helper. Its store ID is needed to check it. |

The diagnostic copies changed only the worker entry and popup; every verdict above comes from the unmodified store package.

### Belongs in PR #775, not duplicated here

- `chrome.identity.getRedirectURL()` as a synchronous function (Copyleaks).
- `webRequest.ResourceType` with WebKit's accepted values, `scripting.ExecutionWorld`, and `idle`/`management` stand-ins (AdBlock).

### Not fixable in Vane today

- **Runtime enums in content scripts** (GPTZero). WebKit defines `runtime.OnInstalledReason` only in the main world. Vane injects compatibility scripts into workers and extension pages, but not into the isolated content-script world. That world is WebKit's named `WebExtension-<uniqueIdentifier>` world ([WebExtensionContextCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm)), so a document-start user script in that world might work. Whether it would run before the extension's own content scripts was not tested.
- **`cookies.onChanged` details.** WebKit fires the event without the changed cookie.
- **`identity.launchWebAuthFlow` and `oauth2`.** There is no Chrome identity integration in Vane; it would need its own web-authentication window.

Run logs and the result files are kept locally under `~/.cache/vane-task-evidence/arc-extensions-2026-11-23/`.

## Side panels and Claude in Chrome — 2026-11-22

Vane now supplies `chrome.sidePanel`, and stand-ins for Chromium-only namespaces that carry their events and constants and no methods. The unmodified official **Claude** extension (“Claude in Chrome”, Web Store ID `fcoeoabgfenejglbffodgkkbkcdhcgfn`, version **1.0.107**, MV3) installs, and its button opens its side panel docked beside the page, showing Claude's signed-out **Log in** screen. Nothing past that screen was tested, and Claude's page actions cannot work on WebKit.

**Build and package.** macOS 27.0, debug test host built from this change on `main` at `fe03b5f4`, with an isolated temporary `VANE_DATA_DIR` and a fresh profile. The CRX came from Google's public update endpoint (SHA-256 `be64eb4dd905ed7ff50a421d9fd423293e4ce8b56c0fdee24fa4eaf17987a434`) and was unpacked without changes. No Claude account was used.

**How it works.** A script defines `chrome.sidePanel` in the extension's worker (through the existing worker bootstrap) and in its pages. Calls reach the host as a `tabs.create` for a reserved URL inside the extension's own origin, which the host consumes before any tab exists. WebKit resolves `tabId` and `windowId`. The same bootstrap defines the missing namespaces listed in [Extensions and integrations](INTEGRATIONS.md#compatibility-and-validation).

| Step | Before this change | With this change |
| --- | --- | --- |
| Install and background start | Failed: “The background content failed to load due to an error” (`WKWebExtensionContextErrorDomain:6`). The worker's top level calls `chrome.notifications.onClicked.addListener` and other absent namespaces. | Installed and started; no context errors reported in the run. |
| Button | Not reachable. | `action.onClicked` ran Claude's own `sidePanel.setOptions({tabId, path})` and `sidePanel.open({tabId})`. No tab was created. |
| Panel | None. | `sidepanel.html?tabId=…` loaded in the extension context, 360 points wide beside a 590-point page in a 1200-point window. Text: “Log in — Claude in Chrome is available to all paid plan subscribers”. |
| Second press | None. | The panel stays open, as in Chrome: Claude does not set `openPanelOnActionClick`, so the press reaches its `onClicked`, which opens the panel that is already open. |
| Narrow window | None. | At 960 points the panel narrows so the page keeps 420; at 700 it is hidden, still open, and returns when the window widens. |

One crash was found and fixed on the way: an extension page hosted by Vane (options window or side panel) that navigated a subframe raised `WKWebpagePreferences._customUserAgent must be nil for subframe navigations`. Claude's panel does this.

**API availability measured in WebKit** with Claude's exact permission list, in both the worker and a page (134 `chrome.*` paths that Claude's code references were probed):

| Claude needs | WebKit | Consequence |
| --- | --- | --- |
| `sidePanel` | Absent; supplied by Vane | Panel opens. |
| `debugger` (`attach`, `sendCommand`, `onEvent`) | Absent; events only in Vane, methods undefined (since emulated in part: see the section above) | **Page actions do not work.** Claude clicks, types and takes screenshots through the DevTools protocol (`Input.dispatchMouseEvent`, `Input.dispatchKeyEvent`, `Input.insertText`, `Page.captureScreenshot`, `Runtime.evaluate`, `Network.*`). WebKit offers extensions no equivalent. |
| `tabGroups`, `tabs.group`/`ungroup` | Absent; constants and events only | Claude's tab group is not created. |
| `identity.launchWebAuthFlow` | Absent; undefined | Claude's silent OAuth refresh path fails. Whether interactive sign-in completes was not tested. |
| `notifications`, `offscreen`, `downloads` | Absent; events only, methods undefined | No notifications, no offscreen audio/GIF document, no downloads from the extension. |
| `runtime.connectNative` | Hidden by Vane | Claude reports the desktop app and Claude Code connection as absent. |
| `runtime.getContexts` | Absent | Claude's ⌘E command cannot tell that its panel is open, so it does not toggle. |
| `action.getUserSettings`, `action.setBadgeTextColor`, `favicon` | Absent | Cosmetic. |
| `scripting`, `tabs`, `storage` (local and session), `alarms`, `webNavigation`, `declarativeNetRequest`, `permissions`, `commands`, `windows`, `runtime.onMessageExternal`, `tabs.captureVisibleTab` | Present | Not exercised beyond start-up. |

**Not tested:** signing in, chatting, reading a page, any tool call, the options page, the `claude.ai` content scripts, shortcuts, and an assembled signed app. Presence of an API in the table is not evidence that Claude's use of it works.

Automated coverage: `ExtensionSidePanelTests` loads a synthetic MV3 worker that registers listeners on absent namespaces at its top level and opens a per-tab panel from `action.onClicked`. It checks the panel page, tab scoping, `window.close()`, `openPanelOnActionClick` and its toggle, the shared panel, a per-tab `enabled: false`, `open()` refused without a user gesture, that the stand-ins expose events and constants and leave methods undefined, and the panel's width limits. A second test covers a tab kept in a swiped-away Space, a tab moved to another window, tab close, window close, a private window, a store parked behind another profile's, and an extension without the permission. A third covers `setPanelBehavior` at a worker's top level, the `_execute_action` shortcut toggling the panel, and the `chrome.runtime` constants in a manifest content script. The first test also covers the close button's path, an open after a click in the key window, and a page-reported gesture (simulated: tests cannot click). The Claude runs were local probes and are not in the suite; their logs and snapshots are under `~/.cache/vane-task-evidence/claude-side-panel-2026-11-22/` (first run) and `~/.cache/vane-task-evidence/claude-side-panel-2026-11-23-review-fixes/` (repeated after the stand-ins lost their methods).

## Password-manager unlock and autofill — 2026-11-21

The unmodified official Bitwarden **2026.11.0** Firefox (Manifest V2) package signs in to a vault, unlocks it again after a restart, and fills a login form in Vane. The same runs repeat the ad-blocker and page-changer checks with current packages. This is the first authenticated password-manager result; the earlier sections keep their original verdicts.

**Build.** macOS **27.0.1 (26A434)**. Vane `main` at `149dadc3` plus the harness commit `06ce3fac`, version **0.2.4-nightly.20261120.1 (740)**, debug configuration, assembled by `./make-app.sh debug`. The test copy was re-signed ad hoc with Vane's sandbox entitlements under its own bundle identifier and run with an isolated `VANE_DATA_DIR`; executable SHA-256 `2d9b6f77a82fc06f4f3c4a19f047945cbc0ef85fac90ac55e0e100af79705083`. The released v0.2.3 binary was not exercised separately.

**Packages.** Each archive's SHA-256 matched GitHub's release-asset digest, and every extracted file was compared byte for byte with its archive entry (no mismatches, no extra files).

| Fixture | Version | Manifest | Exact asset | Archive SHA-256 |
| --- | --- | --- | --- | --- |
| `bitwarden-firefox` | 2026.11.0 | MV2 | [bit-dist-firefox-2026.11.0.zip](https://github.com/bitwarden/clients/releases/download/browser-v2026.11.0/bit-dist-firefox-2026.11.0.zip) (tag commit `28b247ac34877882aaef4faea082a9f3bb201114`) | `f4bbf83709fa314abfadd47bfa0c6b2a3b1debe76a273574e65642ec70e83094` |
| `darkreader-mv3` | 4.9.135 | MV3 | [darkreader-chrome-mv3.zip](https://github.com/darkreader/darkreader/releases/download/v4.9.135/darkreader-chrome-mv3.zip) | `6c59ba11f9733f6f1ba42e79113e2bf764c41f9d50103b527af736f55fbccf47` |
| `ubolite-safari` | 2026.1116.1650 | MV3 | [uBOLite_2026.1116.1650.safari.zip](https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1116.1650/uBOLite_2026.1116.1650.safari.zip) | `eed328928569264b321d9fc162c19a68167db54e36c1be51328d5739439907b4` |

**Account.** No Bitwarden cloud account and no real credentials. A disposable [Vaultwarden](https://github.com/dani-garcia/vaultwarden) **1.37.5** container listened on loopback only. `scripts/seed-extensioncheck-vault.mjs` registered a random throwaway account, stored one login item for `http://127.0.0.1`, and wrote `fixtures/bitwarden-account.json`. Bitwarden's release builds refuse any server URL that is not HTTPS, so the container served TLS with the publicly downloadable `*.local-ip.sh` certificate, whose name `127-0-0-1.local-ip.sh` resolves to `127.0.0.1`. That certificate's private key is public: use it only for a disposable loopback server.

**Results.** Two fresh data directories, two processes each; all four runs exited 0 with no failed finding.

| Workflow | Observed |
| --- | --- |
| Install | Production review, staging and activation of the unmodified package. |
| Desktop-request handling | **Review Error-Only Mode…** accepted for Bitwarden before use. Without it the popup never becomes usable (see below). |
| Sign-in | In Bitwarden's own popup: self-hosted server set, email and master password entered, **Log in** pressed. The server logged the token grant and vault sync, and the popup showed the vault with the seeded item under “Autofill suggestions”. |
| Unlock after restart | A new Vane process restored the accepted installation with its vault locked. Entering the master password on Bitwarden's lock screen opened the vault. |
| Autofill | With the login form open in a new tab, **Fill** in the popup set the form's username and password fields to the seeded values. The harness compares both fields exactly. Passed in the install process and in the restarted process. |
| Dark Reader 4.9.135 | Styled the known-white page (9 injected stylesheets, changed computed background); popup and options rendered; brightness option set to 110 and read back in the next process with the same extension identity. |
| uBO Lite 2026.1116.1650 | Popup and dashboard rendered; `easylist`, `easyprivacy` and `ublock-filters` enabled; a temporary rule added through its context blocked the controlled script (zero requests reached the server) while the control script ran. This checks request blocking through WebKit, not filter-list coverage on real sites. |

The harness drives Bitwarden's visible fields and buttons from script; it does not use the pointer or change the package. Before pressing **Fill** it waits until Bitwarden's form reader answers in the page, using the extension's own `collectPageDetailsImmediately` message as the readiness signal.

To reproduce:

```sh
# 1. A disposable server on loopback with a certificate macOS already trusts.
docker run -d --name vane-extcheck-vault -p 127.0.0.1:18643:80 -v "$TLS:/ssl:ro" \
  -e 'ROCKET_TLS={certs="/ssl/server.pem",key="/ssl/server.key"}' \
  -e DOMAIN=https://127-0-0-1.local-ip.sh:18643 -e SIGNUPS_ALLOWED=true \
  -e I_REALLY_WANT_VOLATILE_STORAGE=true vaultwarden/server:1.37.5
# 2. A new folder under Downloads holding only fixtures/, with the three packages
#    above unpacked as fixtures/bitwarden-firefox, darkreader-mv3 and ubolite-safari.
node scripts/seed-extensioncheck-vault.mjs https://127-0-0-1.local-ip.sh:18643 \
  "$DIR/fixtures/bitwarden-account.json"
# 3. Run twice: the second process checks restoration and unlock.
VANE_DATA_DIR="$DIR" Vane.app/Contents/MacOS/vane extensioncheck
```

Without `fixtures/bitwarden-account.json` the harness keeps its earlier signed-out Bitwarden check.

### What does not work, and what was not tested

- **Error-only mode is required.** On WebKit Bitwarden runs its Safari code, which asks a desktop app to `sleep` between vault-timeout checks. Vane hides the native-messaging functions by default, so the call throws, Bitwarden retries at once, and its background page never yields: the popup did not reply and the earlier harness ran into its 240-second deadline. With **Review Error-Only Mode…** accepted in the extension manager, those requests receive paced errors and the popup works. The mode stays off after installation until it is turned on in Manage Extensions → Compatibility.
- **The Chrome (MV3) package still fails.** `bit-dist-chrome-2026.11.0.zip` (SHA-256 `07cf19b8f79e649005fdeee67c85d3cf31c735449a01a37a5b9f0287732605a5`) installs, shows its popup in error-only mode, and completes the server sign-in. The popup then stops answering. A sample of the extension's web process shows its main thread parked in `WebCore::WorkerThreadableWebSocketChannel`'s constructor, called from the service worker's `new WebSocket` on the worker's main-thread run loop, in every sample of that capture. Bitwarden opens a notifications socket after sign-in. The capture comes from one run; the popup also stopped answering after sign-in or restart in two other processes. No synthetic extension was used to confirm it, so this is an observation about this package on this WebKit, not an established general rule.
- **A tab that was open before the install can miss the extension's messages.** In several exploratory runs in the same session as the install, Bitwarden's `tabs.sendMessage` got no answer from its form reader in the tab that predated the install, and **Fill** reported “Unable to autofill the selected item on this page”. In two instrumented runs reloading that tab did not help while a new tab answered at once; two later runs did not reproduce it. It was not seen in three runs after a restart. A synthetic extension installed without a later reload answered in the old tab. The cause is not established, so the verified path opens the form in a new tab.
- **The fill shortcut is taken.** Bitwarden's ⇧⌘L “autofill login” command collides with Vane's Show Library shortcut, which takes precedence. Filling from the popup is the verified path.
- **Desktop integration is unavailable**: biometric unlock and anything else that needs the Bitwarden desktop app, because Vane has no native-messaging hosts.
- **Not tested**: Bitwarden cloud accounts, two-step login, the inline autofill menu, save and update prompts, passkeys, cards and identities, and sync notifications. Bitwarden's background reported an unhandled `chrome.scripting.ExecutionWorld` error from its passkey script registration; `scripting` is not available to this MV2 package.
- A first install opens Bitwarden's own welcome page at `bitwarden.com` in a new tab.

Run logs, result files, the renderer sample and the instrumented traces are kept locally under `~/.cache/vane-task-evidence/byearc-extensions-2026-11-21/`. Instrumented copies of the package were used only to diagnose failures; every verified result above used the unmodified archive contents.

## iCloud Passwords investigation — 2026-11-22

Checked on macOS 27.0.1 against Apple’s helper 27.0.1 and the installed Developer ID build of Vane. No credential was requested or read; macOS killed the helper at launch, before it could reply.

**Extension route: blocked by macOS.** `/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json` points at `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app` and allows only `chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/` and `chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/`. `codesign -dvvvv` shows the helper carries a parent launch constraint. The process that spawns it must either hold the Apple-managed `com.apple.developer.web-browser.public-key-credential` entitlement or match one of Apple’s hard-coded signing-identifier and team pairs (Chrome, Edge, Firefox, Arc, Brave, Vivaldi, Opera and others). Vane has neither. Spawning the helper from an unlisted process with a `{"cmd":14}` capabilities frame ended in `SIGKILL` before any reply; the kernel logged `AMFI: Launch Constraint Violation (enforcing) … (Constraint not matched)` and the crash report gives `CODESIGNING` / `Launch Constraint Violation`. The kernel enforces this, so no bridge, wrapper or origin string in Vane can work around it.

That entitlement is the one already pending for passkeys (see [Real-site compatibility](REAL-SITE-COMPATIBILITY.md)). If Apple grants it, the constraint’s entitlement branch would be satisfied, but three things remain unverified: the helper is itself App Sandboxed and Vane is too, so a direct child launch may fail and need a separate unsandboxed launcher holding the entitlement; Vane would need the native-messaging bridge described in [Native messaging investigation](#native-messaging-investigation); and unpacked extensions get a Vane UUID origin, not the Chrome Web Store ID the host manifest lists.

**Native route: none found.** Per Apple’s documented model (not tested here), `ASAuthorizationPasswordProvider` and shared web credentials return items only for an app’s own associated domains, and Passwords items sit in Keychain access groups that need Apple-private entitlements. Credential provider extensions supply credentials; they do not read Apple’s. AppKit adds **Edit → AutoFill → Passwords…** to an app’s Edit menu, but a standalone probe (active app, key window) found it enabled for `NSTextView` and `NSSecureTextField` and disabled when a `WKWebView` password input had focus.

**Other desktop password managers.** A generic bridge was not built or validated. A host launched from the sandboxed browser is expected to inherit its sandbox (untested).

## MV3 navigator repair — 2026-10-31

The selected worker navigator identity now comes from a synchronous resource bootstrap on system WebKit. Controlled native fixtures set the actual background WebView's native UA to a deliberately wrong value and verify the first vendor classic instruction and first module dependency see the selected value. Lifecycle coverage includes generated workers, worker recreation, setting changes and host restoration with storage, grants and profile ownership intact. A signed MV3 fixture rejects altered resource Data against the original seal. The unmodified official Bitwarden Chrome **2026.10.0** package passed the local SDK startup check with the bootstrap and unchanged source bytes; no authentication/vault/popup acceptance is inferred.

The former worker-UA advisory is replaced by blocking native coverage. Historical native-UA failures below retain their original verdicts and predate this explicitly authorized JavaScript repair. See [worker navigator identity](EXTENSION-WORKER-IDENTITY.md) for resource URLs, signature handling, API scope and CI gates. Required latest-target CI and actual-main verification remain delivery gates.

## Focused regression scope

Run from the repository root:

```sh
python3 scripts/run-native-tests.py --filter 'Extension|SafariAppSignatureTests'
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

## Runtime-script diagnostics and open acceptance — 2026-10-28

The startup check previously treated every reported context error as an activation failure. System WebKit can report `WKWebExtensionContextErrorDomain:7` (script execution) after the background has successfully loaded. Activation therefore raced optional-feature errors. Vane now retains these diagnostics in the extension manager while requiring successful background completion separately. Background-load errors (code 6), unknown codes, other domains, callback errors including code 7, cancellation, and the existing startup deadline remain blocking.

The live MV2 regression registers a nonce message listener, throws an optional-feature error, and requires a newly created popup document to receive the nonce from that background. It failed with the previous classifier under a running AppKit loop and passes with the repair. The literal domain/code matrix also checks that diagnostics remain visible. Focused local validation on macOS 27.0.1 (26A434): **34 passed**, zero failures, primary status 0 and cleanup status 0:

```sh
VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT=300 python3 scripts/run-native-tests.py \
  --build-system native --jobs 4 \
  --filter 'ExtensionBackgroundStartupTests|ExtensionBackgroundWatchdogTests|ExtensionCodeStoreTests'
```

Issues [484](https://github.com/notnaki/vane/issues/484) and [513](https://github.com/notnaki/vane/issues/513) remain open. This activation repair establishes neither real-package acceptance nor an MV3 worker identity repair:

- **Bitwarden:** The official Developer ID 2026.10.0 package was copied without resource changes and checked against its per-file SHA-256 inventory. The source archive SHA-256 is `a44011745891f7aefe6bc34e8dc0feb3e3e5002630b9c084fe15be8a26c0746c`. A signed sandboxed task-only entry point linked to Vane's current debug objects exercised the production installer and an actual anchored action popup in an isolated profile. Installation succeeded; the welcome JavaScript did not reply within the original **20-second** deadline. A post-failure sample of the exact popup renderer showed JavaScriptCore draining microtasks and repeated extension namespace/runtime property lookups. The sample does not identify the executing JavaScript document or establish the loop's cause. Close/reopen and restoration acceptance were not reached. The Mac App Store download stalled on its account sheet; this vendor package is not acceptance for the reporter's exact Store package. No credentials were used. Both task app processes exited and the scoped WebKit store was positively retired.
- **MV3 workers:** The previously captured first-start failures remain valid. Current upstream source still [establishes a remote worker context and sends its UA in separate steps](https://github.com/WebKit/WebKit/blob/da4d88f94a06e713938e0aa76943578d00626772/Source/WebKit/UIProcess/WebProcessPool.cpp#L815). The connection [initializes its fallback UA without an application name](https://github.com/WebKit/WebKit/blob/da4d88f94a06e713938e0aa76943578d00626772/Source/WebKit/WebProcess/Storage/WebSWContextManagerConnection.cpp#L103) and captures the effective value at worker installation. This audit found no supported host operation that makes those initial steps atomic. Page configuration, a later page-JavaScript reply, or a later worker UA setter is not proof of the worker's initial identity. This historical audit did not include a worker workaround. The later authorized navigator bootstrap and its blocking regression coverage are described above.

After the initial stalled download, the user installed the exact Mac App Store **2026.10.0** package: Apple signing chain, team `LTZ2PFU5D6`, receipt present, and all **185 resource files byte-identical** to the vendor package. Vane's signed Safari-app installer also succeeds, followed by the same original **20-second** welcome-JavaScript failure. Its scoped store was retired. A separate normal-startup run of the complete Vane executable restored the accepted extension as enabled with the code7 diagnostic visible; that bounded UI experiment produced no passing popup acceptance verdict.

Local evidence is retained under `~/.codex/artifacts/vane-extension-repair-2026-10-28/`, including signed-binary/source provenance, owned process kernel identities, original failure reports, renderer samples, and retirement logs. Later inspector experiments are diagnostic arms only and cannot change the original failed acceptance verdict. Early inspector attempts missed the local inspector's `developerExtrasEnabled` prerequisite; their connection timeouts do not establish the extension's cause. A corrected clean-page inspector control subsequently passed.

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
| Bitwarden vault/autofill/sync/passkeys/biometrics/native desktop integration | **Unverified/unavailable** in this 2026-10-12 run; no real account or credential data used. Vault unlock and autofill were verified later, in the 2026-11-21 section above. |
| Synthetic **Vane Runtime Smoke 1.0.0 MV3** | Installed through manager review. Native Command-Shift-Y through the normal app event monitor changed the example.com page title to “Extension command verified”. Native webpage right-click included “Verify Vane Extension Page Menu”; activating it changed the title to “Extension menu verified”. Pinned toolbar action opened its rendered popup. No real extension compatibility is inferred from this synthetic fixture. |
| Synthetic assembled harness fixture **1.0 MV3** | Real anchored popup and native options page worked. Routed NSEvent command dispatch succeeded on the first run; later runs timed out obtaining browser key focus, so those later command attempts are unavailable. The normal-app keyboard check above independently verified the main monitor path. |
| Cross-profile/private/lifecycle | Automated content-script, controller/origin/storage, private restriction, command routing, moved/selected/closed tab, window closure, and stale-options checks passed. In a real private window, installation was disabled and the manager showed the Private profile with an explicit extension restriction. Manual multiple-regular-profile UI checks remain unverified. |
| Test app ownership | Every launch recorded exact bundle/executable, PID, and start time. All three harness and three UI processes exited; each UI process used its own “Quit” confirmation. The final tracked PID 55048 exited normally, and the regular `/Applications/Vane.app` instance remained running with its original start time. |

The opt-in `extensioncheck` CLI runs only from a signed sandboxed `.app` with an isolated Downloads data directory. First use requires that directory contain only `fixtures` (and optionally `.DS_Store`), with `darkreader-mv3`, `ubolite-safari`, and `bitwarden-firefox` unpacked from the exact assets above. An optional `fixtures/bitwarden-account.json` for a disposable self-hosted server on loopback (other hosts are refused) adds the vault unlock and autofill checks described in the 2026-11-21 section. It mints a directory-bound marker; reruns require that marker. It explicitly accepts these known fixtures, denies extra runtime prompts, serves only bounded loopback fixtures, records outcomes, and retains accepted installs/settings for a fresh-process check. It never uses a normal profile or real credentials. Run it twice with the same isolated directory to verify Dark Reader’s saved option and identity. The first restart exposed an incorrect white-baseline harness assumption because restored Dark Reader had already styled the page; the harness now explicitly checks for restored styles. That was corrected in the harness, not hidden as an extension failure.

Prefer the uBO Lite Safari package for WebKit testing: its declared APIs are recognized in this parser check. The Chromium variant requests `offscreen` and `userScripts`. The Bitwarden Firefox package avoids Chromium `offscreen`/`sidePanel` requirements, but still declares APIs omitted by WebKit. A popup opening is not proof of blocking or password autofill. Verify actual content/style changes or a known filter match before recording those as passed.

### Password-manager startup investigation

The unmodified Bitwarden **2026.9.3 Firefox MV2** package was reviewed and attempted in the signed sandboxed app. Background initialization failed with `TypeError: null is not an object (evaluating 'this.device.toString')` at `background.js:1:740229`; Vane retained no activated installation. No login, vault, or credential data was used. This is a failed compatibility result, not a working password-manager claim.

At the exact release commit, [Bitwarden’s browser detector](https://github.com/bitwarden/clients/blob/8246ae9c9a484a0a69f8b27203034555fb872523/apps/browser/src/platform/services/platform-utils/browser-platform-utils.service.ts) recognizes specific Firefox, Chromium-family, DuckDuckGo, and Safari tokens, then returns a null device for an unrecognized browser. The startup client converts that result to a string. The recorded run used bare WebKit identity in extension pages, unlike Vane’s Safari identity in ordinary tabs.

Extension pages now inherit the same selected user agent as ordinary tabs, including the default Safari version/product tokens. The controller’s [basis web-view configuration](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller/configuration-swift.class/webviewconfiguration) supplies the default Safari suffix. Full custom identities and subsequent Develop changes use a guarded WebKit webpage preference, with a guarded creation callback applying the identity before background pages/workers start. Existing extension views receive the public `customUserAgent` update without replacing controllers or changing grants/storage. A running worker can retain the identity from its creation until WebKit recreates it. If WebKit removes the full-identity preference, extension pages fall back to default Safari and the manager discloses that custom extension identity is unavailable.

The synthetic `ExtensionUserAgentTests` cover background/worker and popup startup identity, live MV2 background/popup changes, popup recreation, host restoration, and unchanged access. This does not revalidate the historical Bitwarden package or establish authenticated workflows. Selecting Safari branches also introduces [Safari host integration](https://github.com/bitwarden/clients/blob/8246ae9c9a484a0a69f8b27203034555fb872523/apps/browser/src/browser/safariApp.ts), including native messaging that Vane does not implement. Reviewed upstream packages are not patched. Chromium Bitwarden remains parser-only evidence.

## ZIP import decision

ZIP import is deferred. [Apple’s public initializer](https://developer.apple.com/documentation/webkit/wkwebextension/init(resourcebaseurl:)) accepts a directory or ZIP containing `manifest.json` and reports invalid manifests/archives. Its documented contract does not establish Vane’s required extraction bounds or path/symlink policy. Use Finder to extract the official archive, then select or drop the folder containing `manifest.json`. There is no new archive dependency.

A future importer must extract into profile-owned staging before review, reject absolute/traversal paths, symlinks/special files, conflicting or case-ambiguous entries and unsupported encrypted archives, enforce entry/per-file/aggregate bounds while streaming, check integrity, require one unambiguous manifest root, and validate resources before activation. Failed/cancelled import must clean staging without changing accepted code. Passing an arbitrary ZIP straight to WebKit does not establish these safeguards.

## Native messaging investigation

Native-host execution is deferred. Public macOS 15.4+ WebKit hooks include [one-time messages](https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:sendmessage:toapplicationwithidentifier:for:replyhandler:)) and [persistent message ports](https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:connectusing:for:completionhandler:)). Their default handling can forward to an app extension’s handler when loaded from that bundle; unpacked resources have no such handler. Ports must be retained while connected. The missing piece is Vane’s host integration, rather than an absence of public WebKit hooks.

[Chrome’s native messaging design](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) registers a host manifest with an absolute executable path on macOS and exact allowed origins. A separate process exchanges UTF-8 JSON framed with native-order 32-bit lengths; documented limits are 1 MiB from host and 64 MiB to host. Persistent ports and one-time messages have different process lifetimes.

Before adding execution, Vane needs its own host registration/discovery and trusted identity mapping; explicit per-extension/per-host consent and revocation; profile/private restrictions; validated executable/manifest paths and signing/sandbox/distribution policy; process launch without shell evaluation; framing, JSON, size, backpressure and timeout bounds; and port/process teardown on disable, removal, profile deletion, and quit. Diagnostics must exclude message payloads and credentials. An unpacked manifest key is not proof that its code is an allowlisted store extension. Reusing another browser’s registry or pretending Vane’s UUID origin is a production Chrome origin would bypass that trust design.

[Bitwarden’s upstream integration guide](https://contributing.bitwarden.com/getting-started/clients/browser/biometric/) describes its desktop proxy and host manifests, which normally allow production extension IDs; development IDs require explicit configuration. Its Safari bundle integration differs from an unpacked Chromium package. Vane’s public hooks and stable UUID storage identity do not automatically enable Bitwarden desktop biometric integration.
