# Manifest V2 compatibility

Vane keeps the system WebKit engine. WebKit executes MV2 background pages,
content scripts, storage, messaging and browser/page actions, but its `webRequest`
listeners cannot cancel requests, redirect them, or change headers. Recognizing
`webRequestBlocking` in a manifest does not implement those operations. The
extension consent and manager disclose that distinction.

Current Chromium uBlock packages also read `chrome.privacy` while importing their
API adapter. Vane provides a narrowly scoped startup shim for MV2 uBlock only:
the three privacy setting objects exist, and their `get`, `set` and `clear`
methods throw explicit unsupported-setting errors. They never read or change
browser preferences. This lets uBlock's existing error handling continue startup;
its browser-privacy switches remain unavailable and are disclosed in the manager.
An implemented native WebKit privacy namespace is left untouched.
The same scoped shim binds `runtime.getURL` to its native runtime receiver,
preserving Chromium's behavior when uBlock stores that method on its own object.
When WebKit omits `webNavigation.onCreatedNavigationTarget`, Vane derives a
tab-level event from native `tabs.onCreated` and the tab's live opener identity.
New tabs opened beside a source tab and adopted web popups retain that weak opener
reference. Closed, locked or cross-profile openers are not exposed. The fallback
does not invent source frame or process identifiers and does not establish full
popup-blocking parity. An implemented native event is left untouched.

Other narrowly scoped adapters let the package finish startup and maintenance:

- Legacy alarm-create callbacks use WebKit's real promise-based operation. Native
  round trips verify that both callback and promise calls create the named alarm.
- `onUpdateAvailable` accepts listener registration, but Vane has no Chrome-style
  deferred update/reload phase: accepted updates replace their contexts through
  Vane's reviewed update flow.
- `handlerBehaviorChanged` acknowledges an empty blocking-listener decision cache;
  it does not add blocking webRequest.
- Missing `requestIdleCallback` uses an eight-millisecond cooperative timer budget,
  with cancellation and timeout reporting. This is a timer fallback, not an idle
  signal from WebKit. It applies to extension pages and the installation's isolated
  content world on subsequent document loads. Reload existing pages to initialize
  their content-script environment. Native implementations are preserved.

The adapters retain native API wrappers within their own extension realm so
compatibility members survive garbage collection. They do not alter other
extensions, rewrite vendor files or grant new permissions. Neutral timer helpers
in an existing page controller disappear with that controller; they retain no
extension context and run no work after extension code stops calling them.

## uBlock Origin static filters

An enabled MV2 extension named **uBlock Origin** can supply its selected static
filter lists to Vane. The adapter reads the extension's actual background page,
using its own cache API and decoder. It supports both classic `vAPI.cacheStorage`
and the current package's `js/cachestorage.js` module. This also handles caches
that uBlock compresses or stores outside `browser.storage.local`. It never opens
WebKit storage databases, edits the accepted package, or downloads filter lists.
Missing cached lists can use a package-local `assets/assets.json` resource; a
missing selected list stops the bridge instead of installing an incomplete policy.
Updates and remote list retrieval remain uBlock's responsibility.

The selected lists, enabled **My filters**, and **Trusted sites** feed WebKit's
compiled content rules. An explicitly empty selection stays empty. Hostname
trust covers that host and its subdomains; literal URL trust stays exact, and
supported wildcard URL directives retain their host boundary. Arbitrary regular
expression trust directives pause the bridge because translating them can change
which pages the user trusted.

The translator reuses Vane's documented EasyList subset and adds hosts-file
entries, `$important` precedence, and `$badfilter` cancellation across lists.
Network exceptions are repeated inside every compiled chunk, before important
blocks. Invalid `$important` exceptions are omitted as they are in uBlock.
Trusted sites apply to all of those rules.
Conditional filter sections and resource types that WebKit would broaden are
omitted and counted. Adapter rules exclude documents: uBlock has separate strict
blocking behavior for main-frame navigation, which a generic URL match cannot
reproduce. Cosmetic rules stay with uBlock so its cosmetic switches remain effective.
No rule is substituted for an unrepresentable operation.

The manager reports active supported/unsupported counts, unsupported reasons,
and bridge failures. Dynamic request decisions, redirects, header changes, CSP,
HTML filtering and arbitrary regex filters remain unsupported. Cosmetics and
scriptlets remain the extension's responsibility; the adapter does
not establish that they work on every site. This is partial uBlock compatibility,
not full uBlock Origin parity. MV3 blockers such as uBlock Origin Lite keep their
native `declarativeNetRequest` path and do not use this adapter.

Rules attach only to normal browsing controllers in the installation's profile,
including controllers already created before installation. They do not attach to
another profile, private pages, or extension pages. Disable, removal and host
retirement detach them. Restricted or denied website access pauses global rules;
the adapter never broadens an extension's permissions. Vane's independent built-in
blocker and its site exceptions keep their own controls.

Settings are checked between compiles on a two-second timer. Compilation runs off
the main actor before WebKit compiles its rule lists. A final settings read rejects
a policy changed during compilation. Compiled identifiers include the installation
and rule-content hash; unchanged policies reuse the same cache entries, and a
successful replacement prunes only that installation's older entries. Reload a page after changing filters or
trusted sites; already loaded resources are not undone. Limits are 256 selected
lists, 32 MB of source text, 10,000 trusted directives and eight compiled chunks.
Read/compile/translation failures detach bridge rules and remain visible instead
of retaining an outdated trust policy. The extension itself can remain enabled.

## Browser survey and implementation sources

The complete [byearc matrix](https://www.byearc.workers.dev/compare/) was inspected
for MV2, including partial, unavailable and unknown entries, rather than treating
all browsers that load an MV2 manifest as equivalent. The site's rows are an index
of claims; the relevant implementation mechanisms were then read at source. The
matrix changes over time, so the groups below describe this investigation, not a
permanent compatibility certification. No peer browser was executed for this audit.

| Matrix group | Browsers inspected | What can transfer to Vane |
| --- | --- | --- |
| Patched Chromium MV2 | Crest, Cra, Ardia, Oblada, Arcium | Their patches disable Chromium's MV2 retirement gate. They rely on Chromium's existing blocking network implementation; the patch cannot be applied to system WebKit. |
| Gecko MV2 | Zen Browser, Floorp; Swell lists partial integration | Firefox retains blocking webRequest. Gecko add-on support does not provide a WebKit network interceptor. |
| System WebKit / mixed partial support | Yab, Nook, Ortix, Tern, Search, Tacet, Zephium, Contrail, Vane, Refrax, Talos, Zigzag, Kaizu, Feather | MV2 loading is useful but inherits WebKit's non-blocking webRequest. Engine-specific behavior remains bounded by the active engine. |
| WebKit uBlock bridge | myBrowser | An independent static-list adapter is feasible. It is partial, not synchronous webRequest. Its unlicensed source was inspected for feasibility, not copied. Vane uses the extension's cache API instead of reading its private storage database. |
| Other partial integrations | Blanc, Vivaldi, Bow, Sailfish, Luma, Flow, Yalqen, Orb | Partial marks do not establish full MV2 behavior or an implementation usable on WebKit. |
| MV2 unavailable | Arc, Phi, Dia, Aside, Lilo, Meridian, Orbe, Arc Reborn, Stedding, YARC, Viola, Camber, Flecha, Solamar, Sol (sol-browser.app) | No additional working MV2 mechanism to adopt from these rows. |
| Unknown | Emerald, 1zero Browser, Sol (Steven Koulo), Nova, Circa, Acira, Pola | The matrix has no verified MV2 implementation claim; unknown is not evidence of support. |
| No extension system / not applicable | Firn, Lens, SurfPad, Arcky, Ora, Tangent, Somnia | No MV2 implementation to adopt. |

Primary sources read:

- [Crest's Chromium patch](https://github.com/pauljoda/Crest/blob/e16a309b8e8893a88a64816cbad5610285e67138/CrestEngines/Chromium/Patches/manifest-v2-extensions.patch).
- [Cra's equivalent CEF/Chromium patch](https://github.com/VictorKildahl/cra/blob/0495029601a4ca69af3c8f799208d97e41a91461/scripts/cef-patches/extensions-manifest-v2.patch).
- [Helium's patch used by Ardia](https://github.com/imputnet/helium/blob/ecb36f09c4a4140e4cf4e67e77a3150bf3f3e7eb/patches/ungoogled-chromium/extensions-manifestv2.patch),
  [Arcium's patch](https://github.com/dr-baker/Arcium/blob/ea530f4818599a12754b77daaea8e593feb0b443/patches/ungoogled-chromium/extensions-manifestv2.patch),
  and [Oblada's handler patch](https://github.com/Oblada-Browser/oblada/blob/1aa35386007c949c1444b61d5186e6b7c1adcea9/chromium/patches/extensions-browser-manifest_v2_handler.cc.patch).
- [Mozilla's MV2/blocking-webRequest policy](https://blog.mozilla.org/en/firefox/firefox-manifest-v3-adblockers/).
- [WebKit's listener implementation](https://github.com/WebKit/WebKit/blob/b8a175bded4c57f089cf29a17ab0f000dbbd8540/Source/WebKit/WebProcess/Extensions/API/Cocoa/WebExtensionAPIWebRequestEventCocoa.mm): extra blocking options and listener return values do not supply cancellation.
- [myBrowser's bridge design and measured limitations](https://github.com/marvinvr/my-browser/blob/d1cf448d8ffd22ff96e5d5aa3ca392457962bad9/docs/ubo-network-blocking.md), plus its `ContentBlockerController.swift` and `UBOFilterSource.swift` at that revision.
- [Official uBlock 1.76.0 package](https://github.com/gorhill/uBlock/releases/tag/1.76.0), with its cache, assets and trusted-site interfaces. Vane neither bundles nor copies its GPL implementation.

## Validation

Required synthetic native fixtures cover real network blocking, ordinary
exceptions, user filters, trusted-site changes, empty selections, profile/private
isolation and disable cleanup. Pure translation fixtures cover chunk-local
exceptions, important precedence, badfilter, hosts files, conditional boundaries,
case-insensitive options, URL boundaries and policy bounds.

The actual-package native fixture is opt-in, to avoid downloading or bundling a
third-party extension in CI:

```sh
VANE_UBLOCK_FIXTURE_DIR=/path/to/uBlock0.chromium \
  python3 scripts/run-native-tests.py --build-system native --jobs 1 \
  --filter ExtensionFilterBridgeTests
```

A pass verifies only the named fixture, package and local WebKit version. It does
not certify all uBlock features or real-world ad-blocking coverage.

Local evidence on 2026-11-10: macOS 27.0.1 (26A434), Xcode 27.0. The official
Chromium 1.76.0 ZIP had SHA-256
`e76a1912426caa7b8679ad11dd140d1529c23db22ddbe892b6f901e9b7763456`.
The final compatibility cohort passed 16 cases, including completed uBlock
startup, real cache serialization/decoding, real named alarms, content-script
initialization, real HTTP blocking, opener events and lifecycle controls. The
related cohort passed 57 selected cases with one existing live-store opt-in skip.
Both wrapper runs returned primary 0 / cleanup 0 and retired their exact owned
hosts and stores. Logs are retained under `/tmp/vane-manifest-v2-artifacts/` as
`api-lifetime-green.log` and `final-related-regressions.log`.

Integration on main `295d0033494e49a11954ddd9355acee66a332852` exposed a
regex-option parsing interaction with that base's expanded filter compiler.
The bridge now shares the compiler's regex-aware delimiter, so a terminal `$`
anchor cannot hide document or imprecise resource restrictions. The regression
first reproduced seven wrongly emitted rules, then passed after the repair;
anchored-regex badfilter and important precedence also remain covered. Current-base
validation passed 18 compatibility cases (including the official package) and
64 related cases with one existing live-store opt-in skip, zero failures. Both
wrappers returned primary 0 / cleanup 0, verifying retirement of six and 33 exact
owned backends respectively. Evidence: `integration-regex-red.log`,
`integration-core-green.log` and `integration-related-green.log` in the same
artifact directory. The superseded baseline build was stopped before tests;
its preserved `integration-core.log` records primary -15 / cleanup 0.

Final current-base review additionally found whitespace-normalized resource
options bypassing admission, and duplicate badfilter preprocessing losing the
compiler's domain-member canonicalization and repeated-option safeguards. Both
were reproduced before repair (`integration-whitespace-red.log` and
`integration-badfilter-red.log`). The bridge now shares option normalization and
delegates badfilter validation/canonicalization to the compiler separately for
ordinary and important rules. Fixtures also verify priority isolation. Conditional
badfilters are now counted in skipped-rule diagnostics; the original expected
count failed in `integration-preflight-count-failure.log`, then its assertions
were strengthened to require both exact skip reasons. Final combined validation
completed 87 cases, with one existing live-store opt-in skip and zero failures;
`integration-final-green.log` records primary 0 / cleanup 0 and verifies all 39
exact owned backends retired.

The actual package still reports the explicit privacy denial, a missing local
fallback asset (`pgl.yoyo.org/as/serverlist.txt`), and WebKit rejecting an `abp:*`
context-menu target pattern. These diagnostics remain visible; this work does
not add that subscription-menu scheme or claim those warnings are repaired.
Minimum-macOS and required integration CI remain separate gates.
