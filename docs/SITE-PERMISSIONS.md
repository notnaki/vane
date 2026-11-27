# Site permissions on macOS 26 and later

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

External-app links use the requesting frame's exact web origin and profile, separately
from device permissions. The prompt names that origin, including scheme and nondefault
port. Private grants stay within one private tab and are not saved. Host-only permissions
from older versions require a new answer. Navigating or closing the owning tab dismisses
its pending app request. Restoring a backup requires fresh security consent; see
[the security review](SECURITY-AUDIT.md).

| Capability | Supported application hooks | Vane behavior and limits |
| --- | --- | --- |
| Camera and microphone | `WKUIDelegate` media permission request; `WKWebView.cameraCaptureState`, `microphoneCaptureState`, and their setters | Allow Once, saved Allow/Block, private-tab answers, Ask/reset, and stopping the revoked device with `.none`. State/setters cover the whole web view, so revoking one frame’s camera can also stop another frame’s camera. The untouched device continues. |
| Location | WebKit compatibility geolocation delegate on macOS 26; public `WKUIDelegate` request on macOS 27 | Same site decisions. No public API stops individual WebKit location watches. Ask/Block/reset reloads every live page recorded as using the affected origin’s location decision; a completed reload destroys watches and may interrupt other page activity. Cancelling the reload can leave existing watches alive; Vane retains ownership so a later revocation can retry. |
| Pop-ups | `WKUIDelegate` `createWebViewWith`, with tabs' `javaScriptCanOpenWindowsAutomatically` on so popups with no gesture arrive there | A popup the user's click or key opened always opens. For any other popup the main document's answer decides: Ask (the default) blocks it and shows a toast whose Open loads its URL beside the page, without `window.opener`; Allow opens it like a clicked one; Block drops it with no toast. A popup with no URL offers Allow instead. Never prompted. If WebKit's gesture accessor goes away, WebKit blocks these popups again itself, with no toast. |
| Notifications | None in WebKit on macOS. Vane injects `Notification` into the main frame of secure http(s) pages and posts through a `WKScriptMessageHandlerWithReply` bridge to `UNUserNotificationCenter` | Allow Once, saved Allow/Block, private-tab answers and Ask/reset, keyed like camera. `requestPermission()` prompts only during a user gesture (`navigator.userActivation`); otherwise it resolves to the current answer. A blocked or unanswered site's `new Notification` fires `error`. `Notification.permission` is right at document start: an isolated-world script holds the profile's saved answers and hands the page only its own; later changes are pushed to open pages. Each web view's shim carries a random key the page can't read, so page code can't post to the bridge directly. Clicking focuses the tab and fires `click` if the same document is still loaded (each document gets a random id, so a reload or later page ignores it); dismissing fires `close`; a closed tab's notifications are removed, private tabs' at quit, and any left from an earlier run (a crash) at launch. Icons stream through a cookieless session, cut off at 1 MB. Embedded frames have no `Notification`. No service-worker `showNotification` or Push. macOS asks once whether Vane may notify; no entitlement or Info.plist key is needed. |
| Serial ports | None in WebKit. Vane injects `navigator.serial` and does the I/O itself; see [Serial ports](#serial-ports) | A chooser per request; the picked device is remembered for that origin and profile until forgotten. No Ask/Allow/Block answer: there is nothing to allow without a device. |
| Files and folders | None in WebKit for the user's own files (it has the handle classes only for the origin private file system). Vane injects `showOpenFilePicker`, `showSaveFilePicker` and `showDirectoryPicker`; see [Files and folders](#files-and-folders) | Picking is the grant. Edit access to an opened file or a folder asks again in the permission bubble. Lasts for the document only; nothing is saved. |
| HID devices | None in WebKit. Vane injects `navigator.hid` and does the I/O itself; see [HID devices](#hid-devices) | A chooser per request; the picked device is remembered for that origin and profile until forgotten. No Ask/Allow/Block answer: there is nothing to allow without a device. |
| USB devices | None in WebKit. Vane injects `navigator.usb` and does the I/O itself with IOUSBLib; see [USB devices](#usb-devices) | As for HID devices. |
| Bluetooth devices | None in WebKit. Vane injects `navigator.bluetooth` and talks to the radio with CoreBluetooth; see [Bluetooth devices](#bluetooth-devices) | As for HID devices; the grant also names the GATT services the site may use. macOS asks once whether Vane may use Bluetooth. |
| Screen sharing | WebKit’s `getDisplayMedia` flow and macOS source chooser | No public `WKUIDelegate` display-capture permission callback, per-site persistence, capture-state setter, or source-specific stop hook in the macOS 27 SDK. Camera/microphone grants do not authorize display capture. Vane leaves selection, cancellation, and authorization to WebKit/macOS; document destruction ends its capture. No nonfunctional screen-sharing picker is offered. |

Location decisions and the Location row are available on the minimum macOS 26 runtime,
including builds made with Xcode 26. WebKit calls the pre-public
`_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:`
selector on macOS 26; this compatibility hook forwards to the same origin, document,
profile, and private-tab policy as the public callback. Xcode 27 (Swift 6.4) builds also
compile the public macOS 27 delegate behind its runtime availability check. The
compatibility selector is private WebKit API and may change with system releases.
Camera/microphone controls use public APIs available since macOS 12. Existing page
suspension retains its established guarded `_close` fallback.

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
and after the user answers a popover. The captured generation is checked before and after
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

Camera, microphone, and location requests appear in a native permission popover,
anchored below the requesting tab’s address-bar site-controls button (or Page Actions
in the compact bar). If that control is hidden or absent, the popover uses the top of
the requesting window. The bubble names the site (including nondefault ports) and requested device;
insecure HTTP keeps its scheme, and accessibility help includes the full origin. Not Now
and Escape deny this request without saving a decision. Allow grants once, until the
tab navigates or closes. The Allow button’s context menu also offers Allow Once,
Always Allow (Allow for This Private Tab in private browsing), and Don’t Allow, which
saves Block. macOS device authorization remains separate.

A pending popover leaves browser navigation available. A busy window rejects a second
permission prompt; other windows remain usable. While a popover is pending, Vane checks
its owner and main document every 150 ms, cancelling on replacement, hiding, window
transfer, or closure. Explicit lifecycle events and task cancellation also cancel it.
Closing a prompt’s window cancels that prompt without forgetting capture ownership for
a shared document that survives in another window; actual document teardown owns grant
expiration. A cancelled/stale answer cannot save a decision. Revocation rechecks the
pending request after asynchronous document validation, so a late validation result
cannot resurrect an Allow. Closing the bubble denies without saving.

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

## Serial ports

System WebKit has no Web Serial API. Vane adds one without patching WebKit: a page script
defines `navigator.serial` (`requestPort`, `getPorts`, `connect`/`disconnect`, and
`SerialPort` with `open`, `readable`, `writable`, `setSignals`, `getSignals`, `getInfo`,
`close`, `forget`), and each call is a script message answered natively with termios and
`ioctl` on the `/dev/cu.*` node. Bytes cross as base64. The packaged app carries
`com.apple.security.device.serial`; without it the sandbox refuses the `open`.

The page script runs in the page's own world, so it is trusted with nothing. Every message
is checked again natively:

- **Who.** The main frame only, in a secure context (HTTPS, or HTTP to `localhost` or a
  loopback address). Frames get no `navigator.serial`: `WKFrameInfo` cannot say whether a
  parent delegated `serial` to a child, so none are served. Opaque and `file:` origins
  have no scope and get nothing.
- **Which device.** Only one the user picked in the chooser for that exact origin
  (scheme, host, port) in that profile. The page never names a path; it holds an opaque
  id. A grant follows the device by USB vendor, product and serial number, or, for a
  device without a serial number, by vendor, product and port. A different adapter in the
  same socket does not inherit it.
- **When the chooser may open.** Only with a user gesture. A script in a separate content
  world confirms `navigator.userActivation` and tells Vane; a request that arrives
  without that, including one posted straight to the message handler, is refused. One
  chooser at a time, only for the page on screen and only when the origin asking is the
  one in the address bar, and it closes when that page navigates, hides or closes. A
  camera or location question that arrives while it is open is turned away, as it would
  be by another permission bubble. Return and Escape cannot connect.

Grants in a regular window are saved until forgotten. A private tab's grants live in
memory and go with the tab. Backups leave grants out, like other security decisions.
Forget one from **Site Controls** (the **Serial Port** row), from **Settings → Privacy →
Site Permissions** (one row per port, or **Reset Permissions…** for the profile; **Reset
Site Permissions…** in the menu does every profile), with `port.forget()`, or by deleting
the profile; an open port closes at once.

Ports close when the document is replaced, the tab closes, or its WebContent process
ends. A tab with an open port is not suspended, whether for being idle or to free memory
under pressure. A navigation that has only started leaves them open, because it may turn
into a download and leave the page in place. A port is opened exclusively, so a second
tab or app gets an error instead of half the bytes; `port.close()` resolves only once the
device is released, so a page can close and reopen it at once (as flashers do to change
baud rate).

Up to 1 MiB received from a device (or the page's `bufferSize`, if larger) waits natively
for the page to read it; past that the device is held back. At most 16 MiB may wait to be
written to one port: a write beyond that is rejected with a `QuotaExceededError`, which
the page script, sending one megabyte at a time, never reaches.

Limits: no Bluetooth service-class ports beyond what macOS already lists under
`/dev/cu.*`; no BYOB readers (`readable` is a default stream, not a byte stream); parity,
framing, break and overrun errors are not reported (a slow reader holds the device back
instead); `navigator.serial` is not in workers or frames. A page restored from the
back/forward cache finds its ports closed and must reopen them, and gets no `connect` or
`disconnect` events until it next calls `getPorts()`, `requestPort()` or
`addEventListener()` on `navigator.serial`.

## Files and folders

System WebKit has `FileSystemHandle`, `FileSystemFileHandle`, `FileSystemDirectoryHandle`
and `FileSystemWritableFileStream`, but only for the origin private file system. Vane adds
the three pickers without patching WebKit: a page script makes handles whose prototypes
are WebKit's own (so `instanceof` and `String(handle)` match Chrome), wraps those
prototypes' methods so they serve both kinds, and forwards each call to a native bridge.
WebKit cannot create a real platform handle for a path, so these are shim objects with
WebKit's prototype rather than WebKit-made objects. File I/O runs off the main thread.

What works: `kind`, `name`, `isSameEntry`, `queryPermission`, `requestPermission`,
`getFile()` (a real `File`), `createWritable()` (`write`, `seek`, `truncate`, `close`,
`abort`, and the `{type}` commands), `entries()`/`keys()`/`values()`/`for await`,
`getFileHandle`/`getDirectoryHandle` with `create`, `removeEntry` with `recursive`, and
`resolve()`. Picker options: `types`, `excludeAcceptAllOption`, `multiple`,
`suggestedName`, `startIn` (a well-known folder or a handle), `id` (remembers the last
folder for this run of the app), and `mode`.

The page script is trusted with nothing. Every message is checked again natively:

- **Who.** The main frame only, in a secure context (HTTPS, or HTTP to `localhost` or a
  loopback address). Frames get no pickers. Opaque and `file:` origins get nothing.
- **When.** A picker needs a user gesture, confirmed from a separate content world as
  for Web Serial; a request posted straight to the bridge without one is refused. One
  picker per tab at a time, as a sheet on the tab's window, only for the page on screen
  and only when the origin asking is the one in the address bar. `requestPermission`
  needs a gesture too, and one click is good for one picker or one question.
- **What.** The page holds an opaque token per pick and names, never paths. Every
  operation resolves the entry again with `realpath` and refuses anything that lands
  outside the picked file or folder: no `/`, `.` or `..` in names, links that lead out
  are not listed and can't be opened, and a folder that was moved or replaced by a link
  is gone. Removing a link removes the link. The panel refuses Chromium's blocked
  locations with "contains system files": `/`, the home folder itself, Desktop,
  Documents and Downloads themselves (their contents are fine), `~/Library` (except
  `CloudStorage`, `Containers` and iCloud Drive), `~/.ssh`, `~/.gnupg`, `~/.config`,
  `~/.cache`, shell and vim startup files, system folders (`/System`, `/Library`,
  `/Applications`, `/usr`, `/bin`, `/sbin`, `/dev`, `/private` apart from temporary
  folders), Vane itself and its own data, and, as in Chromium, any folder that contains
  one of these (a project folder holding a Vane build, say).
- **Where it may write.** Nothing inside a `.git` folder except the object store, refs,
  logs, `HEAD`, `index` and `packed-refs` (so `config` and `hooks/` stay read-only),
  nothing inside `.mvn`, and no file named `.git`, at any depth. A site can't create a
  file Finder follows on a double-click without asking (`.webloc`, `.inetloc`, `.fileloc`,
  `.url`, `.terminal`). New files aren't executable and written files are quarantined, so
  `deploy.sh` in a web IDE is fine. A suggested save name that Finder would run or follow
  (`.command`, `.app`, `.sh` and similar) gets `.download` added and loses any leading
  dots. Blocked names match in any letter case. Saving over an existing file empties it, as Chrome does. A page has at
  most 32 writes open at once. Creates and removes go through the folder's descriptor
  without following links.
- **How much.** Opening grants read. Saving grants read and write. A folder picked with
  `mode: 'readwrite'`, or a later `requestPermission({ mode: 'readwrite' })`, asks in
  the permission bubble ("Allow site to edit files in “name”?"). Return and Escape mean
  Not Now. Don't Allow is remembered for the document: `queryPermission` and
  `requestPermission` then answer `denied`.

Writes go to a copy (macOS's item-replacement folder on the same volume, or a
`.crswap` file beside the target when that is refused) and replace the file on
`close()`, keeping its permissions. Abort, an error, or the page going away leaves the
file as it was. Written files are quarantined like downloads. Files are read and
written in 4 MiB messages.

Grants last for the document: a reload, navigation or closed tab ends them, and a
private tab's picks go when it closes. Nothing is saved to disk. A handle stored in
IndexedDB comes back as a handle in the same run of the app and can call
`requestPermission()` again, which is how vscode.dev reopens a folder after it reloads.
After Vane quits, an old handle reports `NotFoundError`; pick the folder again.

Limits: no handles from drag and drop (`getAsFileSystemHandle`); `move()`, `remove()`
and sync access handles are not supported on picked files; a handle survives a
structured clone only as the value itself or in an array read from IndexedDB, so
`postMessage` to a worker or nested in other objects gives a plain object; `types`
filter the open panel only with `excludeAcceptAllOption` (there is no type menu);
`getFile()` reads the whole file into memory and refuses files over 2 GiB; picks are not listed in Site Controls.

## HID devices

System WebKit has no WebHID API. Vane adds one without patching WebKit: a page script
defines `navigator.hid` (`requestDevice`, `getDevices`, `connect`/`disconnect`, and
`HIDDevice` with `opened`, `vendorId`, `productId`, `productName`, `collections`, `open`,
`close`, `forget`, `sendReport`, `sendFeatureReport`, `receiveFeatureReport` and
`inputreport` events). Each call is a script message answered natively with IOKit
(`IOHIDDeviceOpen`, `SetReport`, `GetReport`, and an input-report callback on a queue of
its own; nothing blocks the main thread). Reports cross as base64. `collections` comes
from the device's report descriptor, parsed in Swift the way Chromium reads it.

The packaged app carries `com.apple.security.device.usb`. Measured with a sandboxed probe
on macOS 27: without it `IOHIDDeviceOpen` fails with `kIOReturnNotPermitted`, whatever
the transport; with it the open works. `device.bluetooth` alone does not help. Listing
devices and reading their descriptors only reads the IOKit registry and needs no
entitlement. Devices are opened without seizing them, so macOS keeps using them too.

macOS may ask for **Input Monitoring** when an app opens a keyboard interface. Most
configurator interfaces (VIA's raw HID, Stream Deck, gamepads) are not keyboards and
need nothing. If the user denies it, `open()` rejects with `NotAllowedError`; Vane does
not ask again itself.

The page script runs in the page's own world, so it is trusted with nothing. Every message
is checked again natively:

- **Who.** The main frame only, in a secure context (HTTPS, or HTTP to `localhost` or a
  loopback address). Frames get no `navigator.hid`: `WKFrameInfo` cannot say whether a
  parent delegated `hid` to a child. Opaque and `file:` origins get nothing.
- **Which device.** Only one the user picked in the chooser for that exact origin
  (scheme, host, port) in that profile. The page holds an opaque id per interface, never
  an IOKit id. A grant follows the physical device by vendor, product and serial number.
  A device without a serial number is known only by vendor, product and the port it is
  in, so, as in Chromium, its grant is kept in memory and ends when it is unplugged.
- **Which reports.** Chromium's HID blocklist: the FIDO usage page (`0xF1D0`) and listed
  security keys are never offered. Keyboard, keypad, mouse and pointer top-level
  collections keep their input and output reports from the page (feature reports, which
  carry settings like backlight, stay reachable). System-control collections are blocked
  outright. Blocked reports are left out of `collections`, are not delivered as
  `inputreport`, and cannot be sent. A device left with nothing is not listed.
- **When the chooser may open.** Only with a user gesture, confirmed from a separate
  content world through `navigator.userActivation`. One chooser at
  a time, only for the page on screen whose origin is in the address bar. It closes
  when that page navigates, hides or closes. Return and Escape cannot connect.

Grants in a regular window are saved until forgotten. A private tab's grants live in
memory and go with the tab. Backups leave grants out. Forget one from **Site Controls**
(the **HID Device** row), from **Settings → Privacy → Site Permissions** (one row per
device, or **Reset Permissions…** for the profile; **Reset Site Permissions…** in the
menu does every profile), with `device.forget()`, or by deleting the profile; an open
device closes at once. Devices close when the document is replaced, the tab closes, or
the device is unplugged (`disconnect` fires, and `connect` when it comes back, if it has a serial number). A page
restored from the back/forward cache finds its devices closed and gets new
`HIDDevice` objects from `getDevices()`. A tab
with an open device is not suspended. Up to 1,024 input reports wait for a page that is
busy; past that the oldest go.

Limits: no `navigator.hid` in workers or frames. Bluetooth HID devices are listed like
USB ones but have not been tried on hardware.

## USB devices

System WebKit has no WebUSB API. Vane adds one without patching WebKit: a page script
defines `navigator.usb` (`requestDevice`, `getDevices`, `connect`/`disconnect`, and
`USBDevice` with its descriptor attributes, `configuration`/`configurations` (with
`USBInterface`, `USBAlternateInterface` and `USBEndpoint`), `open`, `close`, `forget`,
`selectConfiguration`, `claimInterface`, `releaseInterface`, `selectAlternateInterface`,
`controlTransferIn`/`Out`, `transferIn`/`Out`, `clearHalt` and `reset`). Each call is a
script message answered natively with IOUSBLib (USBDevice.swift). Descriptors come from
the copy macOS keeps, so listing a device sends it nothing. Every blocking call runs off the
main thread on its own worker, so a `transferIn` waiting for data does not hold up a
`transferOut`; transfers have no timeout, as in the spec. Data crosses as base64, at most
4 MiB per transfer.

The packaged app carries `com.apple.security.device.usb`, the entitlement WebHID already
needed. macOS 27's sandbox profile (`/System/Library/Sandbox/Profiles/application.sb`)
allows the IOUSBLib user clients, `IOUSBDeviceUserClientV2` and
`IOUSBInterfaceUserClientV3`, only under it; the IOUSBHost framework's clients are not on
that list, which is why Vane uses IOUSBLib. When a macOS driver holds the whole device (a
composite device), Vane carries on as libusb does: interfaces no driver claimed, control
transfers and the configuration macOS already set still work, but choosing another
configuration or `reset()` does not. An interface a macOS driver claimed cannot be
claimed (`NetworkError`).

The page script is trusted with nothing. Every message is checked again natively, against
the device's descriptors and this document's own record of what it opened and claimed:

- **Who** and **when the chooser may open**: as for HID devices (main frame, secure
  context, a user gesture confirmed from a separate content world, one chooser at a time,
  closed when the page navigates, hides or closes).
- **Which device.** Only one picked for that exact origin in that profile, behind an opaque
  per-document id. Grants follow vendor, product and serial number; a device without a
  serial number keeps its grant only in memory until it is unplugged, as in Chromium.
  Chromium's USB blocklist (security keys, the same list WebHID uses) is never offered.
- **Which interfaces.** Chromium's protected classes: an interface any alternate of which
  is audio, HID, mass storage, smart card, video, audio/video or wireless controller
  (Bluetooth) cannot be claimed (`SecurityError`). Transfers go only to an endpoint of the
  selected alternate of a claimed interface, in the right direction. Control transfers to an
  interface or endpoint need it claimed. Standard `SET_ADDRESS`, `SET_CONFIGURATION` and
  `SET_INTERFACE` requests are refused; use `selectConfiguration` and
  `selectAlternateInterface`.

Grants, forgetting (Site Controls' **USB Device** row, Settings → Privacy → Site
Permissions, `device.forget()`, Reset Permissions, deleting the profile), private tabs,
backups, unplugging, the back/forward cache and suspension behave as for HID devices.

Limits: no `navigator.usb` in workers or frames; isochronous transfers reject with
`NotSupportedError`; `configurationName` and `interfaceName` are `null`. Real devices
have not been tried yet: the fixtures use fake devices.

## Bluetooth devices

System WebKit has no Web Bluetooth API. Vane adds one without patching WebKit: a page
script defines `navigator.bluetooth` (`getAvailability`, `requestDevice` with `filters`
(`services`, `name`, `namePrefix`, `manufacturerData`), `exclusionFilters`,
`optionalServices` and `acceptAllDevices`, `getDevices`, and `BluetoothUUID`), and
`BluetoothDevice` with `id`, `name`, `forget()` and `gatt`: `connect`, `disconnect`,
`getPrimaryService(s)`, then `getCharacteristic(s)` and `getDescriptor(s)`,
`readValue`, `writeValue`, `writeValueWithResponse`, `writeValueWithoutResponse`,
`startNotifications`/`stopNotifications` and `characteristicvaluechanged`, and
`gattserverdisconnected`. Each call is a script message answered natively with
CoreBluetooth (BluetoothDevice.swift).

The packaged app carries `com.apple.security.device.bluetooth`: the sandbox's
`(bluetooth)` rule, which reaches `bluetoothd` and the LE ATT service, applies only under
it. `NSBluetoothAlwaysUsageDescription` is in the Info.plist. Nothing touches
CoreBluetooth until a site asks to pick a device (or connects to one it was given), so
macOS asks "Allow Vane to use Bluetooth?" then, not at launch. If the user says no, the
chooser says so and lists nothing. The radio scans only while the chooser is open.

The page script is trusted with nothing:

- **Who** and **when the chooser may open**: as for HID devices.
- **Which device.** Only one picked for that exact origin in that profile. `device.id` is
  random per grant, so two sites never see the same id; CoreBluetooth's own id never
  reaches a page.
- **Which services.** Only those the request named in `filters` and `optionalServices`;
  asking for another rejects with `SecurityError`. Chromium's GATT blocklist: the HID,
  FIDO, and Nordic and TI firmware-update services are never reachable (a filter naming one
  rejects); the reconnection address and serial number string characteristics are hidden;
  the peripheral privacy flag and the client and server characteristic configuration
  descriptors can't be written. Filters on iBeacon manufacturer data are refused.
- **What it may do.** A characteristic's properties decide whether it can be read, written
  with or without a response, or subscribed to. Values are at most 512 bytes.

One connection per device serves every tab that uses it; it drops when the last one lets
go. Grants, forgetting (the **Bluetooth Device** row), private tabs, backups and
suspension behave as for HID devices; a document's connection drops when it is replaced.

Limits: no `navigator.bluetooth` in workers or frames; no `watchAdvertisements`,
`getIncludedService(s)`, `serviceData` filters or `referringDevice`; `BluetoothUUID`
knows the common GATT names, not all of them. Real devices have not been tried yet: the
fixtures use a fake radio.

## Validation and remaining platform coverage

Run the focused fixtures on a logged-in macOS desktop:

```sh
swift test --filter 'SitePermissionTests|SitePermissionWebTests|WebNotification|SharedPresentationTests|LifecycleEfficiencyTests'
swift test --filter 'WebSerialTests|SerialConnectionTests|WebSerialWebKitTests'
swift test --filter 'FileSystemAccessDiskTests|FileSystemAccessWebKitTests'
swift test --filter 'WebHIDTests|WebHIDWebKitTests'
swift test --filter 'WebUSBTests|WebUSBWebKitTests|WebBluetoothTests|WebBluetoothWebKitTests'
./.build/debug/vane selfcheck --pure
python3 scripts/check-permission-display.py
```

The fixtures use isolated profiles/defaults, loopback HTTP, real WebKit frames and
native popovers. Test-only WebKit preferences enable fake camera/microphone devices
before constructing the view. A test-only preference disables WebKit’s focus
requirement in the XCTest host; fake-device requests still pass through Vane’s actual
delegate and native permission popover. Tests inspect live/ended synthetic tracks and
WebKit capture states, navigation, retained-view teardown, and termination of the
fixture’s identified WebContent process. The separate display fixture uses an isolated
app host so WebKit can receive a focused user gesture. It bypasses the chooser with a
fake screen source and retains its stream in a same-origin parent to verify frame
removal ends its track. The runner records its bundle, PID, and launch identity,
verifies exit, and removes the temporary app. Location fixtures dispatch the macOS 26
compatibility selector with WebKit-created frames, verify prompt decisions and document
lifetimes, and verify reload revocation including cancellation and retry. Native
`navigator.geolocation` grant/deny tests run through WebKit’s selected delegate and
Vane’s popover, using a test-only WebKit provider that supplies synthetic coordinates
in place of the physical location source. The test view’s window occlusion check is
disabled because XCTest’s inactive host otherwise leaves geolocation requests queued
for a hidden page; the fixtures still require WebKit to report the document visible.
They run without the macOS 27 SDK/runtime gate, so the minimum-runtime CI exercises
the compatibility dispatch.
These exercise policy and engine cleanup without collecting physical device data or
changing macOS authorization.

The serial fixtures use a pseudo-terminal as the device and answer the chooser
themselves. `WebSerialTests` and `SerialConnectionTests` open no window; a pty has no
modem lines and no exclusive lock, so DTR/RTS and "port busy" are covered by the bit
arithmetic and by hand on hardware, not by a fixture.

`WebHIDTests` parses real report descriptors (a QMK/VIA raw HID interface, a gamepad, a
boot keyboard, a FIDO key, a gaming mouse) and opens no window. `WebHIDWebKitTests`
uses fake devices and answers the chooser itself; real IOKit opens, Input Monitoring and
Bluetooth are checked by hand on hardware.

`WebUSBTests` parses a real configuration descriptor (bulk, interrupt and isochronous
endpoints, two alternates, a HID interface) and `WebUSBWebKitTests` drives a page against a
fake device. `WebBluetoothTests` and `WebBluetoothWebKitTests` use a fake radio and never
create a `CBCentralManager`, so they cannot make macOS ask about Bluetooth. Neither opens
a window or touches hardware.

This is not verification of real TCC Allow/deny/revocation, accuracy of delivered
location coordinates, native screen-source chooser restrictions, audio sharing, or
hardware indicators. Those require an explicitly selected signed app/device session.
macOS authorization may deny or delay access after Vane grants a site. WebKit may also
cache a document’s already-issued permission internally; permission callbacks are not
a promise to run before every track or every location update. The compatibility
delegate controls only the site decision; it does not bypass macOS authorization.
No JavaScript geolocation shim is installed.

Primary references: [Apple media capture delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:decidemediacapturepermissionsfor:initiatedby:type:)),
[WebKit compatibility geolocation delegate](https://github.com/WebKit/WebKit/blob/6403505/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h#L158),
[Apple geolocation delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:requestgeolocationpermissionfor:initiatedbyframe:decisionhandler:)),
[Apple capture state setter](https://developer.apple.com/documentation/webkit/wkwebview/setcameracapturestate(_:completionhandler:)),
[Apple microphone sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone),
[Apple location entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.location),
[Apple macOS location usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationusagedescription),
and [WebKit Cocoa delegate implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/UIDelegate.mm).
The installed Xcode 27 `WKUIDelegate.h` and `WKWebView.h` were inspected alongside these
sources on macOS 27.0.1.
