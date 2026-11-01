# Extension worker navigator identity

Vane supplies its selected `navigator.userAgent` and `navigator.appVersion` to Manifest V3 service workers before vendor code runs. The default identity is Safari; Develop selections also apply. Apple's system WebKit still owns worker execution, networking, security updates, extension APIs, permissions and profile storage. Vane does not ship a WebKit fork.

## Bootstrap and accepted code

Vane derives an in-memory resource view from the accepted installation. A small versioned entry runs the navigator bootstrap, then uses native `importScripts` for classic scripts or static imports for modules. Original vendor resources stay byte-identical, including strict directives, escaped identifiers, comments, BOMs and hashbangs. Module graphs use canonical vendor URLs, so a back-reference to the entry evaluates it once. The guard requires an actual `ServiceWorkerGlobalScope`; reusing the original worker resource in an ordinary extension page does not override that page.

Only the navigator UA and appVersion getters change. Explicit workers get an adjacent wrapper, retaining their directory for relative `importScripts`. Workers generated from `background.scripts` keep their original virtual root. The version binds every accepted resource, selected identity and bootstrap/entry code. It makes WebKit update registrations after settings or code changes; identical restorations retain the same version.

The runtime manifest's worker entry and `self.location` identify the wrapper. Vendor module `import.meta.url`, relative imports and source locations retain their canonical original paths. Code that depends on the exact worker filename, query-only URLs, or equality between vendor `import.meta.url` and `self.location` can observe this difference. Imported scripts retain native CSP enforcement; Vane does not relax policy to load a wrapper.

The original managed files and manifest remain unchanged on disk. Traversal uses anchored descriptors, rejects links/special files, and retains the existing 64 MB per-file, 256 MB total, 20,000-entry and 64-level limits. Signed Safari sources retain their existing Apple signature and accepted-identity checks; every original resource Data is checked against the exact accepted resource seal before derivation. The guarded native resource initializer fails visibly when unavailable. A failed navigator override throws before original worker code executes.

Changing the selected identity rebuilds MV3 contexts. Reloads retain the native controller, runtime identifier, origin, profile store and explicit access decisions, including denied and expiring grants. Overlapping selections settle on the latest identity; removal invalidates a pending restart. MV2 backgrounds, popups and content scripts retain their existing loading paths.

## Chrome API scope

WebKit supplies its own `browser` and `chrome` namespaces. The native fixtures exercise messaging through both and storage through `chrome`, with matching runtime IDs. The navigator bootstrap does not intercept extension messages, replace those namespaces, grant native hosts, or manufacture Chrome-only capabilities. An absent API needs an equivalent implementation before it can be mapped; changing identity alone does not supply it.

The unmodified Bitwarden Chrome 2026.10.0 package is an opt-in local startup check. Its published release SHA-256 is verified before extraction. Successful startup is not an authentication, vault, popup or general extension-compatibility verdict.

## Blocking regression coverage

`ExtensionUserAgentTests.testServiceWorkerNavigatorIdentityAcrossSelections` is required native coverage. All discovered tests, including that former advisory, run in the normal four CI shards. Planning fails if the required identity probe disappears. There is no worker-UA advisory job, classifier exemption, weakened comparison or skipped replacement.

Controlled native cases deliberately give the real background WebView a wrong native UA, then capture the selected navigator value at the first classic instruction or module dependency. Additional cases cover generated workers, strict/hashbang semantics, module cycles, canonical dependency updates, nested imports, shared page resources, same-context worker recreation, host restoration, changed and overlapping selections, cancellation, storage and controller/profile ownership. A signed MV3 fixture also checks exact-seal tampering rejection and unchanged accepted bytes. Pure fixtures preserve historical evidence parsing and exercise the complete required-check gate.

Required CI must pass on the minimum supported macOS runtime and the latest integrated target before merge. Main retains strict `checks` protection, including administrators. Native failures and their cleanup evidence remain required; an unchanged passing retry does not repair a failure.

## Historical native-UA investigation

The original bare-engine first-start failures in [#513](https://github.com/notnaki/vane/issues/513) remain valid evidence about native worker construction. The earlier platform-limitation disposition predates the user's explicit authorization of this navigator bootstrap. The repair changes the JavaScript surface before extension code runs; it does not claim an upstream WebKit construction fix. Earlier signed-app failures and archived investigation PRs retain their original verdicts.
