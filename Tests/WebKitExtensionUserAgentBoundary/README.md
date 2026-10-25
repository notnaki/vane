# Diagnostic WebKit extension UA boundary repro

This temporary XCTest class isolates WebKit controller/context behavior from Vane's
extension host, settings, tabs, UA preferences and installation system. It is not a
production workaround and does not replace or weaken the six existing UA tests.

The failing target is macOS 26.6.2 (25G83). macOS 27 is a comparison. A fresh local
pass cannot disprove the observed macOS 26 ordered-suite failure.

## Run in a fresh native test host

Coordinate the native/compute lane first. Build once with one job:

```sh
swift build --build-tests --jobs 1
```

Run each arm in a separate wrapper invocation to get a fresh primary XCTest host:

```sh
python3 scripts/run-native-tests.py --skip-build --jobs 1 --filter 'WebKitExtensionUserAgentBoundaryTests/testPublicSafariSuffixReachesMV2AndMV3Backgrounds'
python3 scripts/run-native-tests.py --skip-build --jobs 1 --filter 'WebKitExtensionUserAgentBoundaryTests/testPublicBackgroundCustomUserAgentReachesNewMV3Workers'
```

These commands are instructions, not evidence that this new class has been built
or run. Record exact revision, OS/build, toolchain, each actual exit status, selected
case count and fixture cleanup result. Track owned process PID/start/executable and
verify all primary/cleanup hosts exited. Do not retry a failed identity as success.

## Arms and assertions

1. **Public Safari product suffix, MV2 then MV3.** The delegate genuinely does not
   implement the optional background-creation selector; the test asserts this.
   The public web-view seed appends fixed synthetic products
   `Version/26.0 Safari/605.1.15`. The real action popup records startup UA and
   messages the actual background. Require exactly one of each product token,
   equal popup/background startup/current UA and the expected fixture generation.
   This arm tests Safari product propagation without any background SPI or private
   full-UA webpage preferences. The fixed suffix is a synthetic input, not a claim
   about the machine's installed Safari version or authenticated Bitwarden use.

2. **Known optional callback + public full-UA setter, new MV3 contexts.** A distinct
   delegate implements the exact callback present in the pinned official WebKit
   source and sets only that existing background view's public `customUserAgent`
   before WebKit starts its worker. Run custom identity then full Safari identity
   on the same controller/store/pool, with a fresh origin/generation for each.
   Require that the callback actually ran for the expected context and selected UA,
   actual background named-store identity/persistence, expected worker startup and
   current UA, and the exact generation. This arm is explicitly SPI-assisted.

   The public action popup getter starts its navigation before returning. There is
   no public pre-creation full-UA setter for that WebKit-owned popup. Its startup
   therefore remains the public Safari-suffix control. After its real worker reply,
   assign the popup's public `customUserAgent` and require the current navigator UA
   to equal the selected literal. This avoids a racy popup-startup claim or private
   policy setter while still comparing a correct native page UA to worker UA.

Both arms use a finite test-process-owned pool. Only extension bookkeeping uses a
non-persistent controller configuration, avoiding an unrelated persistent controller
folder. The actual website backend is explicitly the same owned normal named store
in the controller default and seed; it is not an ephemeral/private session. No host,
storage or private-browsing permission is granted. A synthetic generation response
rules out an old worker answering as the new worker. Readiness and callback waits
are bounded by ten-second stage deadlines; no primer view, sleeps to force startup,
reload, navigator rewrite or injected UA shim is used.

Vane's `TestEnvironment` and profile store lookup are used only to obtain a safe,
owned named-backend namespace. `NativeFixtureProfileCleanup` and the native runner
release exactly that backend after contexts, popup views, controller and delegate
references are cleared. The measurement uses no `ExtensionHost`, `Settings`, `Tab`,
private `WKWebpagePreferences`, or Vane UA helper. The callback keeps context/view
references weak. The six existing functional/security regressions are unchanged.

## Interpretation

- A public-suffix MV3 mismatch reproduces without Vane's host or any private UA
  preference/callback. A matching MV2 arm separates the original page/popup symptom
  from the broader worker startup requirement.
- A full-custom page control with a wrong worker response reproduces a native
  worker propagation boundary without the private webpage policy mechanism.
- Callback state describes the observed view; it does not expose WebKit's cached
  per-origin registration UA or the value captured into the worker thread.
- A timeout, missing callback, parse error, registration failure or wrong generation
  is a different fixture/engine outcome, not a confirmed UA mismatch.
- A pass only means these predecessor states did not reproduce the failure. It does
  not authorize dropping the original six assertions, claiming a fix or merging a
  diagnostic head. No credentials, vault access, sync or native-host compatibility
  are tested.

## Primary source references

The macOS 26.5 source tag is a reference, not a verified mapping to macOS 26.6.2.

- [Background creation callback before worker load](https://github.com/apple-oss-distributions/WebKit/blob/WebKit-7624.2.5.11.4/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm#L2430-L2458)
- [Worker landing document construction](https://github.com/apple-oss-distributions/WebKit/blob/WebKit-7624.2.5.11.4/Source/WebKit/UIProcess/WebPageProxy.cpp#L16253-L16276)
- [Worker effective UA selection and capture](https://github.com/apple-oss-distributions/WebKit/blob/WebKit-7624.2.5.11.4/Source/WebKit/WebProcess/Storage/WebSWContextManagerConnection.cpp#L90-L204)
- [Upstream controller seed/store propagation correction](https://github.com/WebKit/WebKit/commit/0350073e737b173a5a7a80ad55a83d52e940b98d)

The public SDK exposes view `customUserAgent`, an appended application-name suffix,
controller/context configuration and background loading. It exposes no worker-UA
setter or completion barrier proving publication before every native worker start.
The optional callback arm therefore cannot establish a public-only API guarantee.
