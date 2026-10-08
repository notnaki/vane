# Site permissions on macOS 27

Vane’s permission store records what a website’s main document may request. macOS device authorization
(TCC and Location Services) separately determines whether Vane may access the device.
Neither a saved Allow nor Allow Once changes or bypasses that authorization. macOS
controls live device indicators and its privacy settings; Vane’s Allowed labels describe
site decisions, not evidence that a device is capturing. The packaged app includes
`com.apple.security.personal-information.location` for sandbox access and the required macOS
`NSLocationUsageDescription` (alongside the existing when-in-use description). This
makes location eligible for system authorization; it does not grant authorization or guarantee delivered coordinates.
Camera and microphone retain their usage descriptions and camera/audio-input
entitlements; microphone also has the current App Sandbox `device.microphone`
entitlement. These packaging capabilities likewise do not grant user authorization.

## Supported decisions

| Capability | Supported application hooks | Vane behavior and limits |
| --- | --- | --- |
| Camera and microphone | `WKUIDelegate` media permission request; `WKWebView.cameraCaptureState`, `microphoneCaptureState`, and their setters | Allow Once, saved Allow/Block, private-tab answers, Ask/reset, and stopping the revoked device with `.none`. State/setters cover the whole web view, so revoking one frame’s camera can also stop another frame’s camera. The untouched device continues. |
| Location | macOS 27 `WKUIDelegate` geolocation permission request | Same site decisions. No public API stops individual WebKit location watches. Ask/Block/reset reloads every live page recorded as using the affected origin’s location decision; a completed reload destroys watches and may interrupt other page activity. Cancelling the reload can leave existing watches alive; Vane retains ownership so a later revocation can retry. |
| Screen sharing | WebKit’s `getDisplayMedia` flow and macOS source chooser | No public `WKUIDelegate` display-capture permission callback, per-site persistence, capture-state setter, or source-specific stop hook in the macOS 27 SDK. Camera/microphone grants do not authorize display capture. Vane leaves selection, cancellation, and authorization to WebKit/macOS; document destruction ends its capture. No nonfunctional screen-sharing picker is offered. |

Location’s new delegate requires Xcode 27 (Swift 6.4) and macOS 27. The minimum runtime
remains macOS 26: older SDK builds and older systems keep WebKit’s location flow and do
not show Vane’s Location row. The geolocation delegate is compiled only with Swift 6.4
or newer and runtime-gated. Camera/microphone controls use public APIs available since
macOS 12. Existing page suspension still uses Vane’s previously established guarded
`_close` fallback; new site decisions and device revocation introduce no production SPI.

## Request ownership and lifetime

WebKit passes the **top-level origin** in both permission delegates. The frame’s
`WKSecurityOrigin` is the **requesting origin**. Vane verifies the supplied top-level
origin against its tab, verifies that the frame belongs to that tab’s web view, and
keys saved decisions by the frame’s scheme, host, port, and profile. Opaque origins
and unsupported schemes fail closed. No host-only legacy Allow is reused.

Embedded camera, microphone, and location requests fail closed, including when
that embedded origin or the top-level site has a saved Allow. This is a compatibility
restriction: `WKFrameInfo` has no supported original-document identifier, while
JavaScript evaluation targets the frame’s current document. An embedded frame could
replace itself at the same URL before the first token read. Public navigation-policy
callbacks can observe subframe navigation actions, but do not provide exhaustive
original-document/destruction identity. Vane does not claim that an asynchronously
read token identifies the original embedded requester. Open a calling/location site
as a top-level tab to use Vane-managed decisions.

The main frame receives a random document token at document start in a separate
`WKContentWorld`. The page cannot replace that token from its own JavaScript world.
Vane records the tab generation and requesting window synchronously in WebKit’s
delegate callback before scheduling work. It reads the token in the requesting main
frame, checks its initial URL, and validates the token before using a remembered answer
and after the user answers a sheet. The captured generation is checked before and after
asynchronous evaluation. A tab generation invalidates outstanding requests on provisional navigation,
commit, release, and WebContent process termination. The frame may survive a
same-origin navigation; its document token does not. Restoring a cached document
renews its token. WebKit’s own request completion still belongs to its original
request/document, rather than a new JavaScript request.

Allow Once is memory-only. A grant belongs to one tab document and cannot be reused in an embedded frame.
Navigation or tab release clears grants. Private saved answers are per private tab, never
inherit regular answers, and disappear at tab closure or app exit. They may survive
navigation within that private tab, as the button “Allow for This Private Tab” states.
Regular saved decisions survive navigation and relaunch until reset.

A pending sheet is attached only to its requesting window. A busy window rejects a
second sheet; other windows remain usable. While a sheet is pending, Vane checks its
owner and main document every 150 ms, cancelling on replacement, hiding, window
transfer, or closure. Explicit lifecycle events and task cancellation also
cancel it. Closing a prompt’s window cancels that prompt without forgetting capture
ownership for a shared document that survives in another window; actual document
teardown owns grant expiration. A cancelled/stale answer cannot save a decision. Revocation rechecks the
pending request after asynchronous document validation, so a late validation result
cannot resurrect an Allow. Escape chooses Don’t Allow and saves Block. Cancelling
or dismissing the sheet through lifecycle/task cancellation denies without saving.

Ask/Block and resets stop affected tracked camera/microphone capture across matching
regular origins and profiles; private changes affect only that private tab. A combined
answer is split when changing one device, preserving the other device’s answer.
Provisional navigation invalidates pending/once answers and stops camera/microphone;
location ownership is retained until commit/destruction because cancellation or a
download may leave the old document and its watches alive. Later location revocation
can still find and reload it. Revocation also retains location ownership until its reload
commits: cancelling that reload can leave watches alive, and the Location row explains
that existing access ends when reload completes. A later Ask/Block/reset retries.
Top-level navigation and page release stop both devices through public
WebKit setters, including when another object retains the web view. Tab/window
closure uses Vane’s existing page teardown; shared tabs retained by another window
keep their owning document rather than destroying it just because a snapshot window
closed. Display capture and location document cleanup remain WebKit’s responsibility.

## Validation and remaining platform coverage

Run the focused fixtures on a logged-in macOS desktop:

```sh
swift test --filter 'SitePermissionTests|SitePermissionWebTests|SharedPresentationTests|LifecycleEfficiencyTests'
./.build/debug/vane selfcheck --pure
python3 scripts/check-permission-display.py
```

The fixtures use isolated profiles/defaults, loopback HTTP, real WebKit frames and
native sheets. Test-only WebKit preferences enable fake camera/microphone devices
before constructing the view. A test-only preference disables WebKit’s focus
requirement in the XCTest host; fake-device requests still pass through Vane’s actual
delegate and native permission sheet. Tests inspect live/ended synthetic tracks and
WebKit capture states, navigation, retained-view teardown, and termination of the
fixture’s identified WebContent process. The separate display fixture uses an isolated
app host so WebKit can receive a focused user gesture. It bypasses the chooser with a
fake screen source and retains its stream in a same-origin parent to verify frame
removal ends its track. The runner records its bundle, PID, and launch identity,
verifies exit, and removes the temporary app. Location fixtures call the actual public delegate with WebKit-created
frame information and verify reload revocation, including cancelling the revocation
reload and then retrying; they request no coordinates.
These exercise policy and engine cleanup without collecting physical device data or
changing macOS authorization.

This is not verification of real TCC Allow/deny/revocation, accuracy of delivered
location coordinates, native screen-source chooser restrictions, audio sharing, or
hardware indicators. Those require an explicitly selected signed app/device session.
macOS authorization may deny or delay access after Vane grants a site. WebKit may also
cache a document’s already-issued permission internally; permission callbacks are not
a promise to run before every track or every location update. No JavaScript API shim
or private permission delegate is used to bypass these platform limits.

Primary references: [Apple media capture delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:decidemediacapturepermissionsfor:initiatedby:type:)),
[Apple geolocation delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:requestgeolocationpermissionfor:initiatedbyframe:decisionhandler:)),
[Apple capture state setter](https://developer.apple.com/documentation/webkit/wkwebview/setcameracapturestate(_:completionhandler:)),
[Apple microphone sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone),
[Apple location entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.location),
[Apple macOS location usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationusagedescription),
and [WebKit Cocoa delegate implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/UIDelegate.mm).
The installed Xcode 27 `WKUIDelegate.h` and `WKWebView.h` were inspected alongside these
sources on macOS 27.0.1.
