# Real-site compatibility evidence

The public-demo pass on **2026-10-06** verified password-session navigation,
print-to-PDF, local WebRTC media, screen capture, clear HLS playback, FairPlay
demo playback, and basic editing in two complex web apps. File-picker uploads
failed in that initial build and passed the follow-up below after the delegate
fix. Passkey authentication could not be completed in the original test build.
These results apply only to the flows and environment below.

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
but the complete flow remains unverified. **Pending** means it was not exercised.

## Results

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

## Supporting checks

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

1. Broaden upload checks to full multiple-file and folder submission, cross-origin
   frames, and drag/drop. Repeat the fixed single-file picker flow on macOS 26 and
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
   pending printing, media and web-app flows in the table before broadening claims.

For a repeat pass, use a fresh test bundle and empty data directory, visit the
linked public sites, perform the listed UI steps and inspect the resulting page
state. For protected playback require the correct encrypted asset, attached
media keys, advancing decoded video and no media error. Record source revision,
macOS/build, signing and test-account scope. Quit and verify exit of every owned
test process, then unregister only its isolated WebKit stores using
`browsercheck-cleanup`; never use the installed profile as a fixture.
