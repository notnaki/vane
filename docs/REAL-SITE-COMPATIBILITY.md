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
  `102ace442f38029d97362e514e010a962975424f` (including the extension fix,
  the reviewed iframe-selection synchronization fix and integration with `main`
  at `ac3fbfc`).
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
playback pass. At that time, `drmcheck <url>` treated video time above one second as
success and incorrectly described it as protected video even without media keys.
The real-service follow-up below corrects that reporting. Additional asset/player
evidence is still required before interpreting progress as proof of decryption.

## Real-service follow-up — 2026-10-08

### Prerequisites and account-service verification

No designated Google, Microsoft or GitHub browser test account, MFA resource,
streaming subscription, or second device/participant on a separate network was
identified for this pass. The request for those resources did not receive an
answer during execution. Repository GitHub CLI access is not a designated
browser sign-in account and was not used as one.

| Requested service flow | Outcome | Missing prerequisite / limit |
| --- | --- | --- |
| Google completed sign-in, redirects, MFA, cancel/retry, logout, quit/relaunch | **Unverified** | Designated Google test account, authorized MFA method and relying party. |
| Microsoft completed sign-in, redirects, MFA, cancel/retry, logout, quit/relaunch | **Unverified** | Designated Microsoft test account/tenant, authorized MFA method and relying party. |
| GitHub completed browser sign-in/OAuth, MFA, cancel/retry, logout, quit/relaunch | **Unverified** | Designated browser test account and authorized OAuth relying party. CLI access does not verify the browser flow. |
| Subscription streaming, captions, seeking, sustained playback and recovery | **Unverified** | Authorized subscription/account and specific service/title. Public FairPlay demos are scored separately below. |
| Cross-network audio/video call, screen transmission, reconnect and interruption | **Unverified** | Authorized second device/participant on a separate network and designated call service. |
| Native capture Stop, camera/microphone/screen permission revocation during a call | **Unverified** | Designated live capture/call setup. Synthetic canvas source stop and permission-state regressions do not exercise native device capture or system revocation. |

No personal credentials, new accounts, paid subscriptions, external participants,
camera/microphone recordings or saved screen captures were used.

### Independent fixtures

The initial implementation source is `a5e699985afba63ea8f4e69baedfaa1009358f07`
(based on `1fe9513c98f82b58d32e9617f7507b6c5b9c00b4`). Host: macOS **27.0.1 (26A434)**, arm64, Xcode **27.0
(27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**. XCTest uses production
Vane `Tab` objects and real system WebKit, with isolated test data; it is not a
signed sandbox app. No distribution or macOS 26 compatibility claim is made.

| Fixture flow | Outcome | Exact exercised behavior and limitation |
| --- | --- | --- |
| Cross-origin redirect/challenge/return | Pass | `SignInCompatibilityTests/testCrossOriginPopupReturnReloadAndLogout`: an opener at `127.0.0.1` opens a popup, HTTP 302 sends it to `localhost`, a synthetic six-digit challenge redirects back, same-origin return writes synthetic cookie/localStorage, posts to opener and script-closes. The opener keeps its URL; reload preserves state and logout removes both stores. This is an MFA-shaped fixture, not OAuth, provider MFA, or process relaunch. |
| Cancel and retry | Pass | `testCancelledPopupLeavesOpenerSignedOutAndCanReopen`: script-closing the challenge leaves the opener signed out; a new popup completes the same synthetic round trip. This tests WebKit's close callback, not every provider's cancellation UI. |
| Video call interruption/reconnection/source stop | Pass | `CallCompatibilityTests/testSyntheticCallInterruptionReconnectAndSourceStop`: a 320×180 canvas at 20 fps feeds two in-page peers. Connected peers decode increasing inbound frames; `replaceTrack(null)` stops frame delivery after draining, reattachment resumes; both peers close, a fresh negotiated pair decodes again; cleanup ends source tracks, closes peers and detaches remote media. Local peers and synthetic video only: no microphone, TURN, network outage, remote call service or screen capture. |
| Permission choices and session/media baseline | Pass | Existing permission grant/block/Ask, cancellation/navigation/window teardown, disk-session restore, decoded video pause/seek/resume/end and navigation clearing checks passed. These do not establish active-device revocation or provider session persistence. |
| DRM evidence reporting | Pass after fix | Five policy regressions cover progress-only false positives, paused/seeking time jumps and frozen frames; a real-WebKit regression invalidates continuity even when a seek completes between polling ticks. `drmcheck <url>` requires advancing consecutive time and delivered-frame samples of the same video, finite time beyond one second, decoded width, active playback and no media error; it distinguishes absent/present modern media keys without claiming subscription licensing. Attached keys alone do not establish an encrypted asset or successful license exchange. A 50-second watchdog bounds missing WebKit callbacks. |

```sh
swift test --filter 'DRMPlaybackEvidenceTests|CallCompatibilityTests|SignInCompatibilityTests|SitePermissionTests|SessionRestoreCompatibilityTests|MediaControlsWebKitTests/testDecodedPlayback|MediaControlsWebKitTests/testNavigationClears|MediaControlsWebKitTests/testDRMProbe|SiteBoostWebTests/testScriptOptIn'
```

The initial focused run passed **27 tests, zero failures**, at 09:47 TRT. The prior
permission baseline passed **17 tests, zero failures**. The DRM policy's red run
executed three tests with three assertion failures before the fix.
The frozen-frame/first-sample red run failed two assertions before requiring
consecutive advancing samples. A fixture-only follow-up releases popup callbacks
explicitly during teardown; its two sign-in tests were rerun separately.

The reviewed final code passed **30 focused tests, zero failures**, at
**10:17:13 TRT**: five DRM policy tests, the real-WebKit seek-continuity test,
synthetic call and sign-in lifecycle tests, media/session/permission baselines,
and the Site Boost test that had failed the initial PR CI run. The debug build,
Python syntax check and `git diff --check` passed. The updated PR still requires
its own current-head CI result before merge.

An intermediate 30-test run failed the new seek fixture and once observed an
empty restored-page title at its immediate assertion. The title check passed on
the subsequent focused runs without a production change. The seek fixture exposed
`seeking=true`, paused, readyState 4 and time 0.5; hidden WebKit deferred its final
frame. The final regression waits for sample invalidation, resumes playback to
complete the seek, then checks identity after completion. That regression passed
individually and in the final focused run. No failed intermediate run is counted
as a pass or used to assert a Vane navigation/media defect.

### Separate signed public-demo playback

The opt-in `python3 scripts/check-browser-smoke.py --public-media` mode uses a
fresh ad hoc signed sandbox bundle, production entitlements, a unique bundle ID
and empty `VANE_DATA_DIR`. It hosts production `Tab`/WebKit and drives the public
[Shaka demo](https://shaka-project.github.io/shaka-player/demo/?build=uncompiled)
through its player API. It uses muted playback; audible output is unverified.
The minimal host window does not exercise normal browser chrome or native player
button interaction. Asset selection and pause/seek/resume use page JavaScript.
The mode replaces the deterministic smoke pass and is never run implicitly by CI.

An initial probe stopped because its instrumentation used a removed Shaka caption
API and checked the previous document before navigation committed. That run earns
no sustained-playback pass and is not a Vane defect. Its owned app (PID 10035,
started 09:39:53 TRT) exited, its cleanup process (PID 10666) exited and one
temporary WebKit store was unregistered. A corrected probe was run separately.

The first corrected bundle's executable SHA-256 was
`29da4c03ee13278388ba30fa764fc5a38c8ca97b2103fb902ec37729eb5dd026`.
Its clear HLS run passed six 15-second sampling intervals, pause (stable for one
second), seek to 30 seconds, resume, and unload/reload recovery. Media time at the
six samples was 46.895, 62.844, 78.779, 94.758, 110.737 and 126.693 seconds;
width 1252, readyState 4, no keys or media/player error. Recovery decoded to
1.014 seconds. No caption tracks were offered by this asset.

In that same run, the Axinom FairPlay asset advanced to 46.851 and 62.385 seconds,
width 1920, readyState 4, `com.apple.fps` and attached keys. English text track 3
was active and its text displayer reported visible (French/German tracks also
available); rendered cue text was not independently verified. At the third
sample it was paused at 75.352 seconds with no media/player error. Thus this
attempt **failed sustained playback** and did not reach recovery. The cause was
not established. Native UI inspection was attempted during that run; this does
not establish that UI inspection caused the pause or that Vane caused it.
PID 12544 (start 09:42:26 TRT) and cleanup PID 14865 exited; one temporary store
was unregistered. An unattended repeat with event diagnostics is scored below.


### Repeats, diagnostics and corrected probe

The unattended repeat (`88698e9818b7458b4dc70fe92950f295b986bae16859565dcb3a3cba5c02bfde`,
source `a5e6999`) did not earn a pass: the clear asset timed out during loading;
FairPlay paused at 44.027 seconds at the first sustained sample. PID 17946
(start 09:48:13 TRT) and cleanup PID 19019 exited; one store was unregistered.
A subsequent probe additionally waited for Shaka's full initialization.

The diagnostic repeat (`5a2a31e51e814b1a8e42cfe2e9d13061f14ef3b79794b40e16d43b28152a51af`,
source `2f44feb` plus initialization/event diagnostics) advanced clear video to
47.038, 62.840 and 78.759 seconds, then failed the fourth sample after a native
pause at 84.897 seconds. FairPlay advanced to 46.993 seconds, then paused at
59.504 seconds. No JavaScript `pause()` calls or media/player errors accompanied
these sustained-run pauses. The FairPlay document was hidden and muted at its
failed sample. WebKit documents
[power-saving restrictions for hidden/offscreen silent autoplay](https://webkit.org/blog/7734/auto-play-policy-changes-for-macos/);
this is a possible contributor, not proof of the cause or a reproduced Vane
playback defect. PID 21946 (start 09:53:15 TRT) and cleanup PID 23385 exited;
one store was unregistered.

Independent review found that time advancement alone could accept a forward
seek on paused video. The regression failed three assertions before the fix.
Source `c2f7147` adds active-playback and delivered-frame checks and resets sample
identity on seeking/source replacement. Native HLS exposed zero
`getVideoPlaybackQuality()` counters on this host, so the probe uses
`requestVideoFrameCallback` when available. Hidden XCTest surfaces did not deliver
frame callbacks; their real-WebKit regression checks seek invalidation, while
actual frame delivery is verified separately below. These failed diagnostic
experiments are not counted as compatibility passes.

The corrected signed `drmcheck` was exercised on a disposable loopback H.264
fixture at `http://127.0.0.1:52084/`, muted at playback rate 0.25. Source
`c2f7147`, executable SHA-256
`e2970c79e22706db7794d0db4256308635d79a55f2fe7b6015450818f400153e`.
At consecutive three-second polls, time advanced from 0.665 to 1.415 seconds,
delivered frames rose from 0 to 7, decoded width was 640, readyState 4,
paused/seeking false and no media error. It correctly reported **PLAYING, no
modern media keys attached**; this is a clear fixture, not a license test.
PID 31730 (start 10:09:39 TRT), cleanup PID 31827 and loopback server PID 31717
exited; one store was unregistered and the temporary bundle/data were removed.



### Final foreground public-demo result

**Pass for the bounded flows below**, not for account services or background
playback. Source `c2f71474991a3c3d9dc726c122977e9d906bb267`; signed executable
SHA-256 `37a2e7bc188f2836e1724f3669f79b43a46e6a8840afe93088d2032e86b72f9e`.
Same macOS 27.0.1/Xcode environment, Shaka
`v5.2.12-main-50-g18f4769a3` (uncompiled). The minimal test window was kept at
floating level and the video scrolled into view. All sustained samples reported
`document.visibilityState=visible`, active playback, readyState 4 and no media or
player error. Native inspection only observed the test window; it did not operate
player controls.

Both assets passed pause (one second stable), seek to 30 seconds, resume beyond
31 seconds, **six 15-second playback intervals**, then unload/reload and decoded
recovery. Each interval required media time to advance more than ten seconds and
an increasing delivered-frame count. This is about 90 seconds of sustained
playback per asset; hours-long, live, audible, background and subscription playback
remain unverified. Reload is a player interruption, not a real network outage.

| Asset | Media time at 15/30/45/60/75/90 s | Delivered frames at those samples | Recovery and limitations |
| --- | --- | --- | --- |
| Clear HLS Big Buck Bunny | 46.947 / 62.341 / 78.178 / 94.162 / 110.128 / 125.390 | 544 / 1006 / 1479 / 1959 / 2437 / 2891 | Width 418→1252; no keys/errors. Reload reached 1.147 s and 2927 frames. No caption tracks. Adaptive widths were observed; explicit quality selection was not tested. |
| Axinom FairPlay HLS Tears of Steel | 46.657 / 62.478 / 78.397 / 94.359 / 109.657 / 125.520 | 430 / 809 / 1191 / 1574 / 1941 / 2321 | Width 1920, `com.apple.fps`, attached keys, no errors. Reload reached 1.057 s and 2348 frames with keys. Native `stalled` events at 40.064 and 84.921 s did not prevent sampled progress. |

FairPlay English track 3 was active and the text displayer visible. At the
30-second sustained sample, the caption container contained 22 characters of cue
text. **Partial captions:** selection and DOM cue production are observed; native
visual rendering was not independently verified. After reload, text visibility
was false and no track active, so caption persistence/reselection is unverified.
No caption pass is inferred from the clear asset.

The task-owned bundle was
`vane-browser-smoke-splthmwx/Vane Browser Check.app` in the macOS temporary
directory. Playback PID 32142 (start **10:10:11 TRT**) exited with code 0;
cleanup PID 33939 (start **10:13:45 TRT**) exited with code 0 and unregistered one
isolated WebKit store. The wrapper removed its temporary app/data directory;
both PIDs were independently checked absent. Other tasks' Vane instances were
left running. Earlier failing attempts remain scored above.


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

## Directory-form root-cause investigation — 2026-10-08

A repeat investigation on **macOS 27.0.1 (26A434), Xcode 27.0 (27A266a)**
started from `1fe9513`. The original opt-in Vane test failed again: directory
selection produced readable files, but the receiver timed out with **zero form
POSTs**. This remains a failed upload, not a successful compatibility test.

The [standalone reproduction](../scripts/fixtures/directory-upload/README.md)
imports only AppKit and WebKit. It uses a default `WKWebView`, an `NSOpenPanel`
returning the selected URLs unchanged, and a navigation delegate that always
allows navigation. A separate loopback Python server records readable selection
metadata and independently validates complete multipart parts. The probe was
ad hoc signed with unchanged production `Vane.entitlements` and a unique bundle
identifier; the synthetic folder was outside the Downloads entitlement.

### Observed boundary trace

| Boundary | Directory root selection | Ordinary file selection |
| --- | --- | --- |
| Picker | `allowsDirectories=true`, `allowsMultipleSelection=true`; native Open returns the `tree/` URL | `allowsDirectories=false`; native Open returns two file URLs |
| Enumeration | Exactly `tree/top.txt` and `tree/nested/child.bin` | Exactly `top.txt` and `child.bin`; empty relative paths |
| Access | `arrayBuffer()` reads both complete files; `/observe` records them | Same complete text/binary reads |
| Form navigation policy | **No POST callback reaches the standalone navigation delegate**; `webViewWebContentProcessDidTerminate` fires | Delegate receives `method=POST`, navigation type `formSubmitted`, returns `.allow` |
| Multipart receipt | **No `/receive/directory` request** | Receiver validates exactly two filenames and all 23 payload bytes |

The standalone diagnostic `ExcUserFault_probe-2026-10-08-093532.ips` reports
`EXC_GUARD`, `GUARD_TYPE_USER`, namespace **WEBKIT (31)**, codes
`0x600000000000001f, 0x0`. Its stack includes
`WebKit::WebPageProxy::decidePolicyForNavigationAction` and
`decidePolicyForNavigationActionAsync`. The Vane XCTest repeat also generated
`ExcUserFault_xctest-2026-10-08-093550.ips`. The standalone signed executable
SHA-256 was `8e0c432165ce1052ec19c63b9d3d90ae662f924d1d371e34d5ac168189e1c77e`.
The source subsequently gained only command-line argument validation.

Synthetic contents in the standalone and signed-Vane checks:

| Directory path / ordinary filename | Bytes | SHA-256 |
| --- | --- | --- |
| `tree/top.txt` / `top.txt` | 17; hex `666f6c64657220746f70206c6576656c0a` | `7929cf2e178b66167d9cab2bdb3fa1b221840e5c27856078916049cea95444c5` |
| `tree/nested/child.bin` / `child.bin` | 6; hex `00ff01800d0a` | `37a6b9c37dd5855326f8891fc0d4daf62843fbbced74f32e0c5cb9c342474f10` |

### Attribution and supported-API limits

The independent client establishes that Vane's scripts, navigation routing,
HTTPS policy, and tab lifecycle are not required to trigger this failure. The
fault originates in the system WebKit upload path on this tested host.

Source inspection at upstream commit
[`b72f728779eeb25525e8f03bce217806b443c0e8`](https://github.com/WebKit/WebKit/commit/b72f728779eeb25525e8f03bce217806b443c0e8)
provides a matching explanation:

1. [`WebPageProxy::didChooseFilesForOpenPanel`](https://github.com/WebKit/WebKit/blob/b72f728779eeb25525e8f03bce217806b443c0e8/Source/WebKit/UIProcess/WebPageProxy.cpp)
   approves each callback URL and issues read-only sandbox handles for those paths.
2. [`DirectoryFileListCreator`](https://github.com/WebKit/WebKit/blob/b72f728779eeb25525e8f03bce217806b443c0e8/Source/WebCore/html/DirectoryFileListCreator.cpp)
   enumerates the selected root into child files carrying relative paths.
3. Form navigation in `WebPageProxy::decidePolicyForNavigationAction` checks each
   encoded file using `hasGrantedSandboxExtensionForFile` before consulting the
   application navigation client. [`WebProcessProxy`](https://github.com/WebKit/WebKit/blob/b72f728779eeb25525e8f03bce217806b443c0e8/Source/WebKit/UIProcess/WebProcessProxy.cpp)
   accepts assumed directory access or exact previously approved file paths;
   picker root approval does not by itself add its children to that exact set.

This is an inference from upstream source and the observed stack, not a claim
that this upstream revision exactly matches Apple's shipped source. The public
[`WKUIDelegate` contract](https://github.com/WebKit/WebKit/blob/b72f728779eeb25525e8f03bce217806b443c0e8/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h)
provides selected URLs or `nil`, without a separate API for approving descendants
while keeping the directory selection unchanged.

Two supported callback experiments ruled out simple URL expansion:
`testChildFileURLsSubmitBytesButLoseDirectoryRelativePaths` receives correct
bytes but loses every relative path and sends only leaf filenames.
`testRootAndChildFileURLsDuplicateDirectoryEntries` creates four entries from
two files: the root's relative-path entries plus two unwanted flat duplicates.
Neither meets the website's folder contract. No safe application-level fix was
established. No private file-grant APIs, universal file access, sandbox changes,
local-document preload, or site-specific JavaScript multipart rewrites were used.

### User-facing handling and validation

Vane now cancels folder requests on the **macOS 27.0 release family** and displays
“Folder uploads unavailable,” explaining that the system engine may stop the
page and offering the site's individual-file option or another browser. It
returns `nil` exactly once, never reports an upload as successful, and preserves
ordinary file selection. The guard is deliberately broader than the one observed
27.0.1 build; retest before removing it or claiming another version is fixed.
macOS 26 and 27.1+ keep their existing picker behavior; successful directory
submission there is **unverified**.

A unique signed Vane app with isolated data displayed that explanation. Native
ordinary-file cancellation left the input empty; reopening and selecting both
fixtures submitted `/receive/files`, and the server verified the table's exact
filenames, lengths and bytes. Its executable SHA-256 was
`5b870d9b9c297f907a9dcfd5aa36c8891572fce35ddbb1162e027f231f45dc4e`.

Focused validation covers explanation dismissal/reopening, navigation,
teardown and window closure with exactly-once callbacks, version boundaries,
ordinary single/multiple picker cancellation, busy/detached requests, nested
relative paths/readability, complete text/binary multipart receipt and an
embedded cross-origin submission. Run:

```sh
swift test --filter 'FileUploadTests|UploadSubmissionTests|SitePermissionTests'
./make-app.sh debug
python3 scripts/fixtures/directory-upload/build-probe.py
```

The focused run passed **34 tests with zero failures**, with two explicit skips
(36 discovered). The signed debug bundle and standalone probe build also passed.

The raw opt-in directory-form failure remains available independently of the
production safeguard. Its normal-suite skip and the intentionally skipped
27.0 native directory-picker acceptance test do **not** count as upload passes.
The standalone fixture README includes task-owned app/server cleanup steps.
