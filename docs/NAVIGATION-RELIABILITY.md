# Navigation correctness on macOS 27

This audit uses local HTTP fixtures and real WKWebView tabs in XCTest on macOS
27.0.1 (26A434), with Xcode 27's SDK (26A425), in a debug build. TestEnvironment
isolates Vane's defaults and files; fixture views use nonpersistent website data.
No regular Vane instance or user profile is used.

## Reproductions and fixes

- Replaying an older navigation's cancellation while a newer request is pending
  stopped the newer spinner. Replaying callbacks after teardown changed tab state.
  Delegate updates now require the owning live view and active WKNavigation.
  Commands claim the identity returned by WebKit before start callbacks arrive;
  macOS 27 main-frame action/response policies also use `mainFrameNavigation`. Subframe
  responses remain independent of main-document ownership. Retired
  identities cannot restart themselves. Stop/release invalidate that ownership. Late popup close and download callbacks
  also reject retired views.
- A simulated failure replaced before finishing consumed a shared “skip next
  history write” flag on the next successful page. Exclusion now belongs to the
  simulated navigation and its back/forward item. A real response/reload clears
  the marker when WebKit reuses that item.
- SPA pushState routes changed the address without entering saved history.
  Committed same-document URL changes now update history and bookmarks, without
  changing document identity. WebKit remains the back/forward authority.
- HTTPS error documents displayed a lock and “Connection is secure” despite no
  successful connection. Simulated error/interstitial documents now show a neutral
  globe and “This page did not load.” They do not imply certificate acceptance.
- Reloading a POST repeated its body without asking. On this OS WebKit reports
  `.reload` plus `POST`, rather than `.formResubmitted`. Unsafe reload/history
  requests and explicit form resubmissions now require a native confirmation,
  defaulting to Cancel. Initial submissions retain WebKit's request/body. A closed,
  moved, hidden or superseded requester cannot use an old confirmation. Consent
  captures its request token before queuing work, so Stop also prevents a queued
  task from opening a stale sheet.
- Reader and certificate evaluation completions also require the document generation,
  so equality of URLs cannot authorize a result from an earlier same-URL document.

## Validation

Run:

```sh
swift test --filter 'NavigationWebKitTests|CertificateChallengeTests|CertificatePromptTests|SessionRestoreCompatibilityTests|SharedPresentationTests|HistoryPersistenceTests'
./.build/debug/vane selfcheck --pure
```

The navigation fixture covers redirects, iframe responses, fragment and SPA back/forward, reload,
stop, held requests, replacement requests, switching the mounted tab while a
request is pending, interrupted Content-Length responses, connection refusal and
recovery, simulated offline failure, native POST consent/cancellation and moving
its requester, native popup opener/close during loading, Basic authentication
cancellation/supersession, attachment downloads, and closing with a held response.
Late delegate replay uses WKNavigation identities returned by real loads; it makes
rare callback ordering reproducible rather than claiming each ordering occurred
spontaneously. Existing certificate fixtures use real SecTrust evaluation and
native sheets with supplied challenges, preserving rejection and profile/port
scope tests. Existing session checks retain duplicate-URL back/forward histories.

HTTP 401 may remain a displayed WebKit document after authentication cancellation;
that displayed response can legitimately enter history. Tests check that loading
ends, chrome agrees with the document, no credentials are sent and recovery works.

This pass does not claim physical network disconnection, production OAuth/provider
sign-ins, Digest/server client-certificate transport, remote-site compatibility,
macOS 26, or notarized-release coverage. Controlled errors and loopback fixtures
exercise the browser's state transitions without weakening certificate or HTTPS
policies. XCTest owns and closes its windows/views; no standalone Vane app is
launched by this suite.
