# Native-messaging error compatibility

Status: user-approved. The user explicitly chose “Implement the error-only mode”, then requested normal browser behavior and security. Approval covers this error-only contract and its explicit per-extension/profile consent; it does not authorize native-host communication.

## Purpose and evidence

Repair issue484's blank Bitwarden popup without enabling communication with native applications. The unmodified signed Store2026.10.0 background repeatedly calls an unavailable `sendNativeMessage("sleep")`, catches its immediate rejection, and spins through microtasks. This starves popup work.

An isolated diagnostic exposing the real WebKit APIs and rejecting both native-message delegate paths opens and reopens the welcome popup under its original deadlines. Immediate errors still generate18695 requests in10seconds. Defined100ms error pacing reduces that to89 requests in10seconds, and a background timer completes. All probe stores/processes were retired. These are diagnostic controls, not production acceptance; the diagnostic runtime interception will never ship.

## Proposed contract

- Existing installations retain their current hidden-API/denied-permission contract until a user explicitly reviews this separate compatibility mode. New installation approval alone must not silently opt in.
- Offer the mode only when an extension declares `nativeMessaging`. Explain: the extension can receive asynchronous errors for desktop-integration requests; communication with desktop apps remains unavailable. Native-dependent features, including biometric unlock or native clipboard routes, are not promised.
- Persist the explicit choice per accepted extension identity and profile. Default absent/old records to off. Provide review and revocation for existing installations; removing the extension clears the choice. An ordinary update retains the choice only under the existing accepted-identity/permission review rules.
- For approved contexts, configure API visibility and WebKit's required `nativeMessaging` grant before controller load. WebKit requires that grant to expose these APIs; the SDK will therefore report it as granted. This is an intentional API/permission-contract change, despite permanent denial of actual app communication.
- Implement both public native-message and native-port controller delegate methods. Every application identifier and payload receives an unavailable error; never invoke, connect, forward to, or read data from a native application. Do not return successful fake `sleep` results or usable ports.
- Defer denial replies by a defined100ms policy to prevent sequential retry churn. This is error backpressure, not a readiness wait. Preserve cancellation and bound retained task lifetimes; never inspect or log message payloads.
- Unapproved contexts keep native APIs hidden and their permission denied. Other permission decisions, profiles, data stores, controllers, runtime identities and user-agent behavior retain their existing rules.

## Integration and failure handling

Use a separate explicit consent decision, accurately labeled in installation/compatibility review. Do not repurpose an old boolean installation approval or imply that native messaging works. Preserve the old context/record on refusal or failed persistence/reload; install/update rollback and restart must retain the accepted contract. Revocation unloads/recreates the context with APIs hidden and grant denied.

The permanent denial delegates apply regardless of approval so WebKit cannot fall back to its automatic Safari `NSExtension` native transport. Assert both exact public selectors before loading an approved context. No private SPI, injected browser API shim, engine fork, or vendor resource modification is part of the product design.

Compact extension windows are a separate user-requested presentation change. They must retain the SDK webview and original tab/profile association; their container does not resolve the background loop.

## Acceptance

- Existing/unapproved installs, refusal, restart, update rollback and revocation preserve denied native grants and hidden APIs. Explicit approval persists only for the correct extension/profile.
- Real SDK callback calls expose `runtime.lastError`; Promise calls reject; native ports disconnect with error. Every native-app dispatch count stays zero, including signed Safari-app sources. Other contexts and previously denied permissions remain isolated.
- A bounded wrapper reproduction proves timers remain runnable and sequential denial cadence follows the defined policy. Test policy with controlled clocks where possible; do not relax native outcomes or original welcome deadlines.
- Uninstrumented production code installs the exact unmodified Store package, presents the actual compact action window, renders welcome with correct identity, closes/reopens with a fresh webview, and repeats after a fresh-process restoration. Retire and verify every task-owned backend/process.
- Pass independent review and strict latest-main required CI, then squash-merge and verify fresh actual-main CI. Issue513 remains open; this design makes no claim to repair worker identity.

Implementation details within this approved contract are the builder's call. Its explicit consent, error-only behavior and permanent native-host denial are required boundaries.

## Browser behavior reference

Native API permission and an available, authorized native host are separate requirements. Chrome documents unavailable/forbidden host errors and callback `runtime.lastError`; Mozilla likewise requires a declared permission and a separately installed, authorized host. Vane will use real WebKit callbacks, Promise errors and port disconnection while providing no native hosts. The100ms denial policy is Vane's resource backpressure, not a claim about other browsers' timing. See [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) and [MDN native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging).
