# Extensions, blocking, permissions, and AI

[Documentation index](README.md) · [Project README](../README.md)

These features depend on WebKit APIs, external code, or external services. Implemented
controls and scoped fixtures do not guarantee compatibility with every site or
extension.

## Extensions

Choose **Extensions → Install Extension…** and select an unpacked MV2/MV3 folder. Before
loading, Vane checks its manifest and referenced scripts, popups, options pages, and
rulesets, then lists the capabilities and website access for consent. Cancel saves
nothing. Approvals and extension data belong to that installation in that profile;
private profiles cannot install extensions.

**Extensions → Manage Extensions…** (also in Settings → Advanced) lists enabled,
disabled, and failed installations in the current profile. **Access & Diagnostics…**
shows the folder, WebKit error details, compatibility limitations, and currently granted
access. Missing or unreadable resources name the manifest entry and file to repair.
Unsupported capabilities are disclosed before installation as well as in diagnostics.

### Updates and recovery

**Update from Folder** validates current files and reviews added capabilities or website
patterns before replacing the context. **Retry** does the same for an inactive
installation. A failed or declined update stops the extension, closes its options/popup
windows, and removes its active toolbar controls while retaining its bookmark, consent,
installation identity, settings, and saved pin for recovery. Repair the folder and
retry. Vane does not keep a backup of unpacked code, roll back folder edits, or monitor
folders automatically; folder changes are otherwise checked on the next launch. Only
install code you trust.

### Disable or remove

**Disable** stops the context and its extension pages, and persists across restart.
**Enable** checks the folder and reuses unchanged consent and `storage.local` identity.
**Remove** clears the bookmark, consent, identity, disabled state, and pin, including
for failed installations; reinstalling uses a new identity and cannot inherit old
settings. Unavailable saved folders remain recoverable when their disk or access
returns, and can be removed while unavailable. Bookmarks that follow a moved folder
carry its consent, identity, disabled state, and pins to the new location on restart.
Disabled installations keep their saved pin; Manage Extensions lets you unpin them to
free one of three slots. Existing installations without a saved approval require review
before loading.

### Runtime access

Runtime requests ask separately. Optional capabilities and sites are not granted by
installation consent. Runtime grants last for the current context session: update,
disable, or quitting ends them. **Revoke Additional Access** clears additional runtime
grants and denials; required manifest access stays approved. Disable the extension to
stop all access. Requests pending when an extension is removed or disabled fail closed.
WebKit enforces permission expiration dates; manifest consent is separate from runtime
grants.

### Compatibility and validation

Vane uses Apple's WebKit WebExtension APIs, not Chromium. On macOS 27, isolated
synthetic fixtures exercise MV2 background scripts and MV3 service workers, runtime
messaging, `storage.local`, action badges/popup declarations, content-script
origin/profile isolation, and runtime permission grant, rejection, revocation,
expiration, and restoration. This does **not** establish general Chrome-extension or
Chrome Web Store compatibility, nor certify arbitrary extensions, real-site behavior,
every API, or full popup interaction. Vane does not provide native messaging hosts,
extension page-menu items, extension keyboard shortcuts, replacement browser pages, side
panels, developer-tools panels, omnibox keywords, or Chrome OAuth integration. Other API
availability depends on the installed WebKit.

Focused regression checks:

```sh
swift test --filter 'ExtensionConsentTests|ExtensionAccessLifecycleTests|ExtensionCompatibilityTests|ExtensionManagementTests|ExtensionRuntimePermissionTests|SitePermissionTests'
```

## Content blocking and filter subscriptions

Settings → Privacy and Security → Content Blocking separates **Import from Disk** (local
snapshots, never downloaded again) from **Subscribe by URL** (HTTPS lists). The built-in
starter list stays available offline. Existing imported snapshots and legacy file
references are preserved. Sources are shared across profiles; the main blocking switch
and site exceptions belong to each profile.

### Subscription updates

URL subscriptions update daily while Vane is running. Vane checks overdue lists at
startup, after wake, and hourly; failed attempts retry after one hour. **Update Now** or
a list's **Update** button retries immediately. Status shows updating, last/next check
times, and failures. Conditional HTTP requests use the accepted list's ETag and
Last-Modified values. Downloads use an ephemeral session, not browsing cookies, and are
limited to 8 MB of UTF-8 text per list.

Vane compiles the combined candidate using WebKit's public `WKContentRuleListStore`
before saving a changed subscription. Download, compilation, or storage failures retain
the accepted source and last working compiled rules, including across relaunch. A saved
base-rule snapshot also lets new site exceptions take effect when a legacy source is
missing. URL text and metadata live together in an atomic
`FilterSubscriptions/subscriptions.json` document; disk imports stay in `FilterLists`.
The feature does not depend on a managed Apple entitlement.

### Site exceptions

**Site Controls → Block Ads on This Site** changes an exception for the exact host and
reloads the page after rules attach. Exceptions also cover that page's embedded requests
and cosmetic rules; subdomains have their own choices. **Filter Lists and Diagnostics**
opens update status, unsupported rules, and saved exceptions. Resume blocking there to
remove an exception, then reload other open pages. Subscription updates preserve
exceptions; private-window choices are not saved as preferences. Private compiled
variants use a separate transient WebKit store, removed on normal quit; the next launch
sweeps crash leftovers while preserving other live Vane instances.

### Supported filter syntax

The converter supports a subset of EasyList: host/start/end anchors, wildcards, network
exceptions, supported resource/party options, positive-only or negative-only domain
restrictions, and ordinary CSS hiding. Resource types follow WebKit's vocabulary:
subdocuments use `document`, and XHR/WebSocket/ping use `raw`. Regex rules, scriptlets,
procedural selectors, cosmetic exception variants, unknown options, mixed/invalid domain
restrictions, and rules inside conditional branches are skipped. Unbalanced conditional
directives reject a subscription update, and each source has independent preprocessing
state. **Unsupported Rules** reports totals by reason and the first 20 samples with line
numbers; local imports can be inspected separately. Vane does not claim full uBlock
Origin or AdGuard compatibility or expose request-by-request block counts.

Focused regression checks (including real WebKit network and cosmetic behavior):

```sh
swift test --filter 'BlockerTests|BlockerSubscriptionTests|BlockerWebKitTests'
./.build/debug/vane selfcheck --pure
```

## Site permissions

Camera and microphone requests open a sheet on the requesting window with **Allow
Once**, **Always Allow**, and **Don’t Allow**. Builds made with Xcode 27 also offer
location choices and a Location row on macOS 27. Allow Once belongs to the requesting
document and expires when it navigates or closes. Embedded camera, microphone, and
location requests fail closed because the public APIs do not identify their original
document reliably. Saved choices belong to the requesting main frame’s exact origin and
profile; private choices stay in memory in that private tab. Site Controls returns
decisions to Ask or Block and stops camera/microphone capture for the affected device.
Revoking location reloads pages using its decision; location watches end when reload
completes. Cancelling the reload can leave existing watches alive until the document is
replaced.

These are Vane’s **site decisions**. macOS independently authorizes Vane to access
camera, microphone, Location Services, and screen recording; Allow in Vane cannot
override a macOS denial. Screen-sharing selection and permission remain managed by
WebKit and macOS. Vane has no supported screen-sharing persistence or per-source
revocation API. See [permission lifecycle and platform limits](SITE-PERMISSIONS.md).

## AI providers and your own keys

Settings → Max lets you choose Apple (on-device), Groq, OpenAI, OpenRouter, or an
OpenAI-compatible HTTPS API. For a cloud provider, enter its model ID, paste your own
API key, choose **Save Key**, then **Test Connection**. Groq defaults to
`openai/gpt-oss-20b`. Cloud providers may charge for usage or impose quotas. Custom
providers need a base URL such as `https://api.example.com/v1` and support for JSON chat
completions.

Every person uses their own key. Keys are stored as local, non-synchronizing macOS
Keychain items, separately for each provider and custom endpoint. No key is bundled with
the browser, committed to the repository, or sent through a Vane server. Test instances
use separate credential namespaces. **Remove Key** deletes the selected provider's local
credential.

Cloud AI handles pinned tab names, download names, and tab grouping. It sends titles,
hostnames, and download naming metadata (with URL queries and fragments removed) to your
chosen provider; it does not upload file contents. Private windows never use cloud AI.
Page summaries continue to use Apple's on-device model. Cloud requests are bounded,
cancellable, and fall back to ordinary title cleanup and grouping on errors or quotas.

The cloud transport checks use an offline HTTP fixture:

```sh
scripts/check-cloud-ai.sh
scripts/check-cloud-ai.sh --keychain # optional isolated local Keychain integration
```

## GitHub Live Folders

A Live Folder is a pinned folder of GitHub pull requests. Create one from a Space’s menu
with **New Live Folder…**. Choose pull requests you are involved in or one repository,
optionally restricted to recent activity. Refresh happens every five minutes, when
unfolded, or through **Refresh Now**. Taking a row out keeps it excluded.

A release with the optional OAuth client secret supports browser sign-in; ordinary
source builds use a personal access token. Rejected credentials are retained for
reconnection.

Developer credential regressions use the real Live Folder response handler with isolated
storage:

```sh
swift test --filter 'LiveCredentialTests|GitHubRenewalTests'
python3 scripts/check-live-credential-persistence.py
```

### Reconnect and troubleshoot

A rejected GitHub credential stays in Keychain while Edit Live Folder offers
reconnection. Ordinary refreshes continue, and a successful retry clears the warning.
Only explicit sign-out or other user-requested credential removal deletes it. For a
real-session check, reconnect in the installed app, quit normally, relaunch the same
signed build, and refresh the folder. If authentication fails again, Console's `[vane]
GitHub` messages distinguish missing/inaccessible Keychain credentials from HTTP 401
responses and record GitHub's request ID. These diagnostics never log tokens or response
bodies.

### OAuth renewal

OAuth sign-ins store the access token, refresh token, and expiry together in the same
scoped Keychain item. Live Folders renews shortly before the access token expires and
can renew after an early rejection, then retries the API request once. Concurrent
folders and app processes sharing a profile serialize token rotation and use the
persisted replacement. A temporary network or Keychain failure retains the credentials;
an unsaved rotated pair is kept in memory while Vane retries its Keychain write. The
regression tests advance expiry and inject OAuth/network/storage responses without using
a real GitHub account. The fresh-process Keychain check verifies both tokens and expiry
survive relaunch with disposable fixture credentials.

Sign-ins saved by older builds need one reconnect because those builds discarded the
refresh token. A revoked or expired refresh token also needs reconnection. Source builds
without the OAuth client secret can still use personal access tokens; they cannot renew
a web-flow OAuth grant. A signed release includes the secret required for renewal. For a
live check, reconnect using that release, quit/relaunch, and refresh after eight hours:
the folder should renew automatically, and Console should record `[vane] GitHub OAuth
credential renewed` without requiring another sign-in.
