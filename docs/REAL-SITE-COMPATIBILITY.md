# Real-site compatibility evidence

The public-demo pass on **2026-10-06** verified password-session navigation,
print-to-PDF, local WebRTC media, screen capture, clear HLS playback, FairPlay
demo playback, and basic editing in two complex web apps. File-picker uploads
failed in that initial build and passed the follow-up below after the delegate
fix. Passkey authentication could not be completed in the original test build.
These results apply only to the flows and environment below.
The **2026-10-08** expansion below adds synthetic end-to-end probes and native
sandbox observations on macOS 27.0.1, including a confirmed folder-upload failure.

## Environment and scope

- Source: `f81388b629e04980477444c71f023ac64a760db8`.
- macOS 27.0, build `26A428`, Apple Silicon; Xcode 27.0, build `27A266a`;
  Swift 6.4. This does not establish compatibility on the minimum macOS 26.
- Debug executable built with `swift build -c debug`, copied into a separate
  ad hoc signed `.app` using the repository's `Vane.entitlements`.
- Executable SHA-256:
  `e2c32f3e119383e2465ca89d8ad46e57dcb4779a72f439542ffe06c4b9661ae1`.
- A unique bundle identifier and an empty `VANE_DATA_DIR` isolated the live
  checks. Vane's system WebKit configuration, page scripts, default blocker,
  and Safari-style user agent remained enabled.
- The user selected public demos only. No personal account, subscription,
  passkey registration, payment, or external call participant was used.
- Native UI actions exercised Vane. Its Web Inspector read page state and
  invoked Shaka's demo asset loader; this was not a test in another browser.

**Pass** means the listed flow was observed working. **Fail** means that flow
was attempted and did not work. **Partial** means capabilities were observed,
but the complete flow remains unverified. **Pending / Unverified** means it was
not exercised or its prerequisites were unavailable. A skipped test is unverified.

## Results

This table records the original October 6 pass. Later evidence is scored separately
in the follow-ups; its pending limits are historical, not superseded claims.

| Area | Public site and exercised flow | Result | Evidence and limit |
| --- | --- | --- | --- |
| Password sign-in | [The Internet](https://the-internet.herokuapp.com/login), published demo credentials, submit and reload | Pass | `/secure` rendered “Secure Area” after sign-in and after reload. The save-password prompt was dismissed. This does not verify autofill, relaunch persistence, federated login, MFA, or embedded/multi-step login. |
| Sign-in providers | Google, Microsoft, GitHub OAuth/SSO | Pending | No real provider account was used. The deterministic smoke checks cover popup creation and scripted closure, not a provider's completed OAuth exchange. |
| Passkeys | [WebAuthn.io](https://webauthn.io/), discoverable authentication and capability probes | Partial | The demo obtained authentication options, but returned a not-allowed error. `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` both returned `false`. No registration or successful assertion was performed; external security keys and cross-device authentication remain pending. |
| File-picker upload | [The Internet uploader](https://the-internet.herokuapp.com/upload), activate Choose File and submit a synthetic text file | Pass after fix | The initial build showed no picker because `Tab` lacked the macOS upload delegate. In the follow-up, the native picker selected `vane-upload-fixture-74bd0015.txt` from Desktop and the server displayed “File Uploaded!” with that exact filename. See the follow-up environment below. Drag/drop, complete multiple-file/folder uploads, and cross-origin flows remain pending. |
| Printing | Same public uploader page, Vane `⌘P`, PDF save | Pass | A one-page, 26,375-byte A4 PDF contained the heading, explanatory text, controls, drop zone, and footer. `pdfinfo`, `pdftotext`, and a rendered PNG confirmed nonblank output. Physical printer output, page ranges, print CSS, iframe documents, and long documents remain pending. |
| Camera/microphone and calls | [WebRTC peer connection demo](https://webrtc.github.io/samples/src/content/peerconnection/pc1/), Start, Call, receive media, hang up | Pass | Local audio/video tracks were `live`; both peer connections reported `connected`, and remote video reached `74.04394175000198` seconds at width 640. Hang-up set both peers to `null`; explicitly stopping the source tracks produced `ended` for both. This is two peers in one page, not a cross-network call. Permission choices and revocation were not independently scored during this live pass. |
| Screen sharing | [WebRTC getDisplayMedia demo](https://webrtc.github.io/samples/src/content/getusermedia/getdisplaymedia/), Start | Pass | The button became disabled and a live desktop capture appeared in the page's video. Navigating away ended the demo document. This establishes capture startup only, not chooser restrictions, permission persistence, an explicit Stop flow, system revocation, audio sharing, or remote screen transmission. No capture was saved to this repository. |
| Clear streaming | [Shaka Player demo](https://shaka-project.github.io/shaka-player-release/demo/), “Big Buck Bunny: the Dark Truths” HLS | Pass | The video reached `7.938578708` seconds, `readyState=4`, `paused=false`, width 418, no media keys and no media error. Pause/seek/resume, quality switching, captions, long playback, and live-stream recovery remain pending. |
| Protected streaming | Same Shaka demo, Axinom “Tears of Steel (HLS AVC - FairPlay - SingleKey)” | Pass | Shaka created a temporary FairPlay session and completed asset loading. After activating the player, `keySystem()` was `com.apple.fps`, `mediaKeys` was present, video reached `10.782965689332848` seconds at width 1280, `readyState=4`, and no media error. This is protected public-demo playback; Netflix, Disney+, Apple TV+, subscription licensing, HDCP and sustained playback remain pending. |
| Other DRM systems | Signed app `drmcheck`; Shaka Widevine sample availability | Partial | Modern/legacy FairPlay and Clear Key CDMs initialized. Widevine and PlayReady returned `NotSupportedError`; Shaka marked its featured Widevine Sintel sample unavailable. Clear Key end-to-end playback was not scored. |
| Canvas web app | [Excalidraw](https://excalidraw.com/), rectangle, text, undo, redo and reload | Pass | After reload, browser storage contained a rectangle and a text element reading “Vane compatibility fixture” (wrapped onto three lines). File import/export, clipboard integration and multiplayer collaboration remain pending. |
| Editor web app | [VS Code for the Web](https://vscode.dev/), New File → Text File, typing, undo and redo | Pass | The untitled editor displayed `const vaneCompatibility = 42;`; undo removed the last typing group and redo restored it. Disk access, downloads, extensions, authentication, remote repositories and workspace persistence remain pending. |

## Upload picker follow-up — 2026-10-06

The macOS upload delegate now presents an `NSOpenPanel` sheet on the requesting
window and passes selected URLs to WebKit. It honors multiple-file and directory
parameters, rejects detached/busy requests, and cancels on navigation, tab
teardown, content-process termination, or window closure.

The same macOS 27 / Xcode 27 environment above was used with a new, uniquely
identified ad hoc signed app, the production `Vane.entitlements`, and an empty
`VANE_DATA_DIR`. Its debug executable SHA-256 was
`f005fad92e672468178d2f11e74e997eba2f0a2b2853e154f08ce27917eb1ea8`.
A synthetic 49-byte text file on Desktop, outside the Downloads entitlement,
was chosen through the native picker. The public uploader confirmed receipt of
`vane-upload-fixture-74bd0015.txt`. This verifies selected-file access in the
sandbox and an actual single-file submission, without personal data.

```sh
swift test --filter 'FileUploadTests|SitePermissionTests'
python3 scripts/check-browser-smoke.py
```

The focused run passed **25 tests with zero failures**: eight upload regressions
and 17 permission tests. Upload checks exercise real WebKit inputs, single/multiple
and folder picker settings, cancel/reopen, navigation (including a picker opened
between provisional start and commit), teardown, window closure,
and rejection of busy/detached requests. The signed smoke run passed **190
real-WebKit assertions** and unregistered **14 temporary stores**; upload dialogs
are covered separately by the XCTest and public-site checks. macOS 26 and an
unchanged notarized release still need verification.

## Compatibility expansion — 2026-10-08

### Environment and evidence boundaries

- macOS **27.0.1**, build **26A434**, Apple Silicon; Xcode **27.0**, build
  **27A266a**. Automated probes used source
  `b589f0f9abb0e742f151fdebae78819d7cbded43` (including the extension fix and
  the reviewed iframe-selection synchronization fix).
- XCTest used real Vane `Tab`/WebKit objects, native print operations and
  synthetic unpacked extensions. It is **not a signed sandbox app**. Upload
  submission tests supply selected URLs through a fixture delegate; native picker
  acceptance is supported by the separate signed-app observations below and the
  existing `FileUploadTests`.
- Native observations used a separate ad hoc signed sandbox app with production
  `Vane.entitlements`, resources, unique bundle ID and empty `VANE_DATA_DIR`.
  Its source was `aaa3d5662fc82f36b259355a60c2c120a306e9c4` plus the
  behavior-preserving `PagePrinting` factory extraction. Its final signed executable
  SHA-256 was `e1e82bb3d5503ba8465eb19a4632586b89e19947df6c9eff3e828eb2eb3d16e8`.
  **This bundle predates the extension fix**; no native extension-relaunch pass is
  claimed for it.
- A disposable HTTP server at `http://127.0.0.1:57596/` received synthetic uploads
  and playback observations. No credentials, subscriptions or personal documents
  were used. The cross-origin automated probe used `127.0.0.1` and `localhost`.
  These are controlled local fixtures, not new public-service compatibility passes.

### Expanded matrix

| Area and flow | Result | Exact evidence | Remaining limit |
| --- | --- | --- | --- |
| Native multiple-file picker → complete multipart submission | Pass | Signed Vane selected `alpha.txt` and `beta.txt`; the server received both files, respectively 23 and 22 bytes. SHA-256: `c65464e9f08c01c4959174ae651c54110ffad7dfb50f9f9fd261b4eaa7c6ac80` and `3691bb552d693c673f660cfe7033fdcd10f5dea8b9fa77793e250dccaea3f23f`. `testMultipleFilesSubmitExactTextAndBinaryBytes` additionally checks complete text/binary multipart payloads and filenames. | Drag/drop, very large files, interrupted/retried transfers and real account upload services are unverified. |
| Cross-origin iframe file submission | Pass (automated) | `testCrossOriginFrameReceivesSelectedFileAndSubmits`: the requesting frame is `localhost`, parent is `127.0.0.1`; exact synthetic bytes reach the server and only the frame navigates. | A fixture delegate supplies the URL. Native frame picker acceptance and third-party service workflows are unverified. |
| Directory picker, recursive paths and readable bytes | Pass / Partial upload | Native picker selected a folder and the input reported two files. `testDirectorySelectionEnumeratesNestedRelativePathsAndReadsExactBytes` checks `tree/top.txt`, `tree/nested/child.txt` and both complete contents. | Selection/readability do not establish successful submission. |
| Directory → ordinary multipart form submission | **Fail** | Native signed app and opt-in XCTest both reset the page before any POST reaches the server. The input had two readable files before submission. macOS generated a `WEBKIT` guard-fault report with `WebPageProxy::decidePolicyForNavigationAction` on the stack. Reproduction below. | No safe public-API workaround was established. Retain this as a failure; the skipped normal-suite reproduction is not a pass. |
| Print CSS and multipage PDF | Pass (automated) | `testPrintCSSAndThreePageDocumentProduceNonblankPDF` uses the production print-operation factory and native `NSPrintOperation` PDF save: exactly three pages, correct per-page text, print-only text present and screen-only text absent. | Three synthetic pages, not sustained large-document printing. Interactive native PDF saving retains only the earlier public-demo evidence. |
| Print page range and embedded document | Pass (automated) | `testPageRangeSavesOnlyRequestedPage` saves only page 2. `testEmbeddedDocumentTextIsIncludedInParentPrint` verifies parent and `srcdoc` iframe text in the PDF with PDFKit. | Cross-origin iframe printing, physical printer hardware, duplex/color settings and cancellation are unverified. |
| Unpacked extension script execution and isolation | Pass (automated) | `testApprovedContentScriptExecutesOnlyInItsProfileAndMatchingOrigin`: MV3 script executes in its approved profile on `https://example.test`, absent in another profile, private tab and unmatched origin. Existing consent/access lifecycle tests also pass. | Store installation, native toolbar/options interactions, arbitrary MV2/MV3 APIs and specific third-party extensions are unverified. |
| Extension identity and `storage.local` host restore | **Pass after fix** (automated) | Before the fix, recreating the production host changed `runtime.id` and returned `missing` for saved storage. `testLocalStorageAndRuntimeIdentitySurviveHostRestore` now preserves identity, extension origin and synthetic value through `ExtensionHost.forget`/approved-folder restoration; uninstall/reinstall gets a new identity and empty storage. `testDeletingProfileRemovesOnlyItsExtensionIdentities` confirms profile deletion clears only its own identity records. | This recreates the host in one XCTest process. An actual quit/relaunch with the fixed signed bundle remains unverified; previously lost data cannot be recovered from its unknown random identity. |
| Decoded H.264 play/pause/seek/resume/end | Pass (automated), native play/pause observed | `testDecodedPlaybackPauseSeekResumeAndEndUpdateTray`: decoded width 640, advancing time, no media error; Vane pauses, seeks to 0.5 s, resumes beyond 0.8 s, reaches ended and updates tray state. Native fixture play/pause recorded width 640, no error and paused time `1.04777908333`. | Muted two-second video. Audible output, autoplay with sound, subtitles, quality changes, sustained HLS/live recovery and subscription DRM remain unverified. |
| Media navigation and embedded/session controls | Pass (automated) | `testNavigationClearsPlayingMediaAndFreshDocumentCanPlay` clears the old tray state and decodes the replacement. Existing embedded-player and session-only-handler probes pass; the iframe control leaves the main-frame decoy paused. | External devices, system media-key delivery and site-specific custom players are unverified. |
| Disk session restoration, duplicate URLs and histories | Pass (automated) | `testDiskSessionRestoresDuplicateURLsDistinctHistoriesSelectionAndPrivateExclusion` saves to disk, releases old pages, reads entries back and restores stable tab IDs, selected second tab, pin/home URL and distinct back histories. Background rows remain lazy; the private session file is unchanged. | Abrupt crash/power loss, interrupted save and cross-version migration are not scored by this probe. |
| Actual quit/relaunch, page storage and selected tab | Pass (native signed fixture) | Two tabs and the selected second tab returned after ordinary confirmed Quit and relaunch without a URL argument. The second page displayed the synthetic localStorage value and cookie. Session JSON contained both original IDs and the selected second ID. | This is an orderly same-build restart, not a crash restore, real login-session restore or an extension restart. |
| Accounts, subscriptions, approvals, hardware and distribution | **Unverified** | No provider account, subscription license, physical printer, external media device or newly provisioned Apple browser entitlement was available for this pass. | Previous public-demo passes remain scoped to October 6. Approval, registration, service authentication and minimum macOS 26 / unchanged notarized-release behavior require separate evidence. |

### Focused validation and known failure reproduction

```sh
swift build -c debug
swift test --filter 'FileUploadTests|UploadSubmissionTests|PrintingCompatibilityTests|ExtensionCompatibilityTests|ExtensionAccessLifecycleTests|ExtensionConsentTests|SessionRestoreCompatibilityTests|MediaControlsWebKitTests/testDecodedPlayback|MediaControlsWebKitTests/testNavigationClears|MediaControlsWebKitTests/testEmbeddedPlayer|MediaControlsWebKitTests/testSessionOnlyPlayer'
```

The focused run executed **42 tests: 41 passed, one skipped, zero failures**.
The skipped test is deliberately an opt-in reproduction that expects a successful
directory POST; it is not counted as verified compatibility. The debug build passed.

```sh
VANE_RUN_KNOWN_COMPAT_FAILURES=1 swift test --filter UploadSubmissionTests/testDirectoryFormSubmissionKnownWebKitFailure
```

On this macOS 27.0.1 host, the opt-in run **failed** after waiting for a POST that
never arrived (timeout assertion and thrown timeout). To reproduce through native
UI, serve a loopback page with `<input type="file" name="files" multiple
webkitdirectory>` inside an ordinary `method="post" enctype="multipart/form-data"`
form. Choose a synthetic folder containing one top-level and one nested file,
confirm `files.length == 2`, then submit. Vane resets to a blank/New Tab document;
the receiver records no request. The native diagnostic report was
`ExcUserFault_vane-2026-10-08-082931.ips` in `~/Library/Logs/DiagnosticReports`;
an XCTest reproduction produced the same `WEBKIT` namespace guard fault.

Upstream source supports a directory-path approval mismatch: the open-panel handler
records the selected root, directory enumeration creates child file entries, and
navigation validates each submitted file against granted paths. See WebKit's
[open-panel/navigation policy handling](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp),
[file-path approvals](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessProxy.cpp),
and [directory enumeration](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/DirectoryFileListCreator.cpp).
This is a source-based explanation of the observed guard fault, not a tested claim
about Safari or every WebKit version. Do not disable file-security checks to hide it.

The broad signed `check-browser-smoke.py` check **did not pass** in this expansion:
one run timed out at `rapid window switches settle in the final owner`; a second,
isolated run timed out at `second profile shows its traffic lights`. A comparison
using the pre-extension-fix starting executable hit the same traffic-light timeout.
Thus this is pre-existing on this host, and remains a failing window-visibility
check; it is not attributed to the extension fix or scored as browser compatibility.
Each invocation's cleanup passed (10, 13 and 13 isolated WebKit stores respectively).

## Supporting checks — original 2026-10-06 pass

```sh
swift build -c debug
python3 scripts/check-browser-smoke.py
swift test --filter 'SitePermissionTests|MediaControlsWebKitTests|PasswordPopupTests'
```

The build succeeded. The signed sandbox smoke run passed **190 real-WebKit
assertions** and unregistered **14 temporary WebKit stores**. The selected XCTest
run passed **45 tests with zero failures**, including 17 permission regressions.
Those fixtures support browser navigation, media controls and permission logic;
they do not replace the live-site results or prove complete service compatibility.

`drmcheck` without a URL reported:

```text
FairPlay (modern)  YES (com.apple.fps, CDM loads)
FairPlay (legacy)  YES (com.apple.fps.1_0, CDM loads)
Widevine          no  (NotSupportedError)
PlayReady         no  (NotSupportedError)
Clear Key         YES (org.w3.clearkey, CDM loads)
```

The initial `drmcheck <Shaka homepage>` did not advance because no asset was
selected; that is not a playback-failure result. Subsequent checks selected assets
in Vane. Switching assets through the uncompiled demo also produced JavaScript
assertions before later asset loads completed, so that experiment does not earn a
Clear Key playback pass. Only the advancing FairPlay video above earns a protected
playback pass. `drmcheck <url>` currently treats video time above one second as
success even without checking media keys; use additional page/player evidence
before interpreting its output as proof of decryption.

## Remaining work and reproduction

### Known pending: authentication and compatibility

Passkeys remain **pending Apple approval and provisioning** for
`com.apple.developer.web-browser.public-key-credential`. The follow-up inspection
on 2026-10-06 found a valid Developer ID signing identity on the test Mac, but no
provisioning profile in Xcode's or MobileDevice's standard profile directories.
The repository's app packager does not currently embed a provisioning profile,
and its base entitlements omit the managed browser capability. A signing
certificate alone does not resolve the negative passkey result.

Apple's [managed browser entitlement requirements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
require approval through the [macOS browser passkey request](https://developer.apple.com/contact/request/macos-browsers-passkeys/).
After approval, enable the capability for `io.github.notnaki.vane`, generate a
matching Developer ID provisioning profile, embed it in the app, and sign with
the authorized certificate and entitlement. Then verify user authorization,
registration, and successful sign-in using a test authenticator. WebKit handles
web-content WebAuthn requests, as described in Apple's
[browser passkey guidance](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers).
The explicit Vane App ID was registered under the developer team on 2026-10-06
after the request form rejected the previously unregistered bundle ID. The user
then submitted the entitlement request, and Apple's confirmation page stated
that the request will be reviewed. App ID registration and request submission
do not grant the entitlement; Apple approval remains pending.

Google/Microsoft/GitHub completed sign-ins, subscription streaming, and
cross-network calls also remain **pending**. They require designated test
accounts (and MFA where applicable), an active test subscription, and a second
device on a separate network, respectively. No new completed live flow is claimed
by this follow-up; the earlier passes remain scoped to the ad hoc debug build on
macOS 27 above. Repeat these checks on macOS 26 and an unchanged signed/notarized
candidate before making distribution compatibility claims.

### Reproduction and next checks

1. Reproduce and resolve the directory form failure above. Extend native frame
   picker, drag/drop, transfer interruption and large-file checks; multiple-file
   and synthetic frame submissions now have scoped evidence. Repeat the fixed single-file picker flow on macOS 26 and
   an unchanged notarized release. Apple's [WKUIDelegate contract](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h)
   describes the callback and default cancellation behavior.
2. Verify passkeys in a distribution build with the required browser capability,
   user authorization and a test authenticator. The current entitlements file
   does not include `com.apple.developer.web-browser.public-key-credential`.
   Apple's [browser passkey guidance](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
   and [managed entitlement requirements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
   explain the provisioning and access prerequisites. The negative fixture result
   alone does not establish how a properly provisioned release behaves.
3. Repeat the listed passes on macOS 26 and an unchanged signed/notarized release
   candidate. Keep release evidence separate from this debug fixture.
4. Use designated test accounts to finish provider sign-ins, redirects, MFA,
   cancellation, logout and relaunch. Use a second network/device for call and
   screen-sharing delivery, reconnect and permission revocation. Complete the
   still-unverified printing, extension, media and web-app flows in both tables
   before broadening claims.

For a repeat pass, use a fresh test bundle and empty data directory, visit the
linked public sites, perform the listed UI steps and inspect the resulting page
state. For protected playback require the correct encrypted asset, attached
media keys, advancing decoded video and no media error. Record source revision,
macOS/build, signing and test-account scope. Quit and verify exit of every owned
test process, then unregister only its isolated WebKit stores using
`browsercheck-cleanup`; never use the installed profile as a fixture.
