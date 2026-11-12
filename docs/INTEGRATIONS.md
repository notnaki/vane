# Extensions, blocking, permissions, and AI

[Documentation index](README.md) · [Project README](../README.md)

These features depend on WebKit APIs, external code, or external services. Implemented
controls and scoped fixtures do not guarantee compatibility with every site or
extension.

## Extensions

Open **Extensions → Manage Extensions…**, **Settings → Advanced → Manage Extensions…**,
or **Manage Extensions** in the command palette. Each resizable manager window belongs
to the profile shown in its header; switching the browser's active profile does not
change that window's installation set. Private profiles cannot install or run extensions.

Search by name, description, or version, and filter **All**, **Enabled**, **Disabled**,
or **Needs Attention**. Counts describe the whole profile, independently of search.
Needs Attention can include an enabled extension whose update failed; Disabled includes
inactive installations. The list shows icons, versions, summaries, state, and enable/pin
controls. Select a row for details; narrow windows use **All Extensions** to return to
the list. **⌘F** focuses search; native list selection supports the keyboard. Motion
follows Reduce Motion and Vane's Battery Saver policy.

### Install and inspect

Choose **Install Extension…** in the manager or **Extensions → Install Extension…**.
Select an installed app containing Safari web extensions, or choose/drop an unpacked
MV2/MV3 folder. For an unpacked extension, select the folder containing
`manifest.json`, rather than its parent. Extract ZIP downloads in Finder first: the
manager does not import local ZIP or CRX files.

For the Chrome Web Store, choose **Install Extension… → From Chrome Web Store…** in
the manager, or **Extensions → Install from Chrome Web Store…**, and paste a store
detail-page link or its 32-letter extension ID. A valid link already on the clipboard
prefills the dialog. On a store detail page opened in Vane, **Add to Vane** replaces
the store's install button. If the store changes its markup, Vane supplies its own
button on the page; the manager's link/ID dialog remains available.

Downloads go directly to Google's HTTPS delivery services without browser cookies.
Before unpacking, Vane verifies the CRX3 developer signature against the requested
extension ID and the production Chrome Web Store publisher signature. The bounded
extractor rejects unsafe paths, links, special files, conflicting entries and corrupt
archives. Downloads are capped at 128 MiB; expanded code has the same 256 MiB total,
64 MiB per-file and 20,000-entry limits as folder imports. Vane then reviews access
before activation and saves a private, profile-scoped managed copy.

Store installations retain their Chrome runtime ID, Vane storage identity, pins and
disabled state across updates. **Update from Store…** checks explicitly. Vane also
checks daily while that profile's extension host is running, on an hourly timer.
Same-access updates can activate automatically; updates requiring added access stay
pending in **Needs Attention** until reviewed through **Update from Store…**.
Unchanged versions and downgrades do not replace healthy accepted code. An explicit
same-version update can repair missing or damaged accepted resources after review;
retained store IDs can also recover an unreadable metadata index without removal.
A failed or declined
update keeps the accepted version. Store support uses Apple's WebKit runtime and
does not add Chrome-only APIs or native messaging; the compatibility section below
still applies. Private profiles cannot install or run store extensions.

MV3 service workers receive Vane's selected navigator identity before their code
runs, including module dependencies. The accepted source stays unchanged on disk;
Vane uses an in-memory bootstrap with a versioned worker URL. Changing the Develop
identity restarts these workers while retaining their approved access and storage.
The runtime remains Apple's system WebKit and keeps receiving Apple's updates.
The native `chrome` and `browser` namespaces retain the APIs WebKit actually supports.
See [worker navigator identity](EXTENSION-WORKER-IDENTITY.md) for details.

For Safari apps, Vane verifies Apple-issued signatures on both the containing app and
its embedded `com.apple.Safari.web-extension` bundle, including sealed resources. The
bundle and signing identifiers must match, and both bundles must have the same verified
Team ID. If the app contains several Safari web extensions, choose one to review.
Unsigned, ad-hoc, modified, or mismatched bundles are rejected before consent. Vane
never derives a signing team or runtime identity from an untrusted manifest or claimed
Info.plist team. Its runtime ID is the genuine Safari `<extension bundle ID> (<Team ID>)`,
so sites can address an allowlisted Safari extension through external messaging.

For unpacked folders, Vane copies regular files into profile-owned staging, rejects internal symbolic links
and special files, and limits imports to 20,000 files/folders, 64 MB per file, 256 MB total,
and 64 nested folder levels. It validates the manifest and referenced scripts, popups,
options pages, and rulesets before presenting installation consent. Review capabilities,
website access, and compatibility limitations before installing. Cancel leaves the
extension uninstalled. Optional permissions are not silently granted. Signed bundle
snapshots use the same size/count limits and allow relative links only when their
resolved targets stay inside the verified bundle. The MV3 runtime resource view
requires regular files and rejects resource links before worker activation.

Details show source, version, required installation access, declared optional
capabilities/sites, current additional grants, keyboard commands, and compatibility
limitations. **Open Options…** appears when an enabled extension declares an options page.
File inputs in options pages and action popups open a native file-selection sheet on
that view’s window. Closing the view, navigating, or disabling the extension cancels
pending selection. The same macOS folder-upload safeguards used by tabs apply.
**Reveal Source Folder** opens its external source in Finder when available. Missing or
unreadable files have recovery guidance; a source warning does not mean accepted managed
code has stopped working.

### Accepted code, updates, and recovery

Vane runs an accepted managed copy from local profile storage. Changes in the external
source folder do **not** apply automatically, including after restart. Use **Update from
Folder…** to select its replacement. Every explicit candidate update is validated and
reviewed before activation, including updates requesting no additional access. Expanded
capabilities or website patterns are called out separately. A valid update keeps the
installation's UUID, extension origin, approved access, settings/storage identity,
disabled state, and saved pin.

Failed validation, declined review, activation failure, or saving failure retains the
previously accepted code and approval. Declining leaves the accepted version running.
If a candidate fails after replacing a context, Vane attempts to restart the accepted
copy. **Retry** restarts accepted code when inactive; **Update from Folder…** can locate
a moved source or select a repaired replacement without creating a new installation.
A successful update replaces the prior accepted revision; there is no manual version
history. Code recovery cannot undo storage or website changes made by a candidate that
already ran.

Background startup reports WebKit errors and stops waiting after ten seconds if WebKit
never completes. A failed candidate is unloaded and its staged copy is removed; failed
restoration keeps accepted code and exposes **Retry**. At launch, Vane also collects
unused revisions created with the current staging lease protocol, while preserving
accepted revisions and stages owned by another running process. Missing, unreadable, or
retained recovery metadata, and older revisions without a lease, prevent automatic
collection when ownership cannot be established safely.

Some WebKit releases can lose extension API bindings when an MV3 worker restarts in
a different process ([upstream WebKit fix](https://github.com/WebKit/WebKit/commit/001f7dbb8bbfc1f05310c7c6eed4e092d674c523)).
If accepted code cannot restart after a failed update, Vane keeps it inactive with a
visible failure and retains its code, approval, identity, and settings. Recreating the
controller may not repair this WebKit state in the current process; quit and reopen
Vane if **Retry** continues to fail.

Safari app installations keep a resource-verified signed bundle snapshot in the
profile and persist the app/extension bundle identifiers and signing team. They are
resolved against the installed app again at launch or enable. **Update from App…** can
select a moved app or check an App Store update. A changed extension is staged, verified,
and reviewed before activation, including same-access updates; changes do not replace
running accepted code silently. A valid update retains the Safari runtime ID, private
origin, approval, settings, disabled state, and pins. Duplicate copies of the same
verified extension update one installation per profile. A missing app, changed signing
identity, invalid signature, or ambiguous replacement fails closed and leaves an entry
with recovery guidance. Reinstall the original app or choose its current location.
Profiles retain separate controllers and extension storage; private profiles run none.

Existing folder installations migrate when next loaded or updated: Vane validates a
separate copy and preserves their UUID, approval, disabled state, pins, and storage
identity. The migration always asks for review before adopting and loading the copy,
including when its required access is unchanged. Newly available page-menu support is
called out explicitly. Disabled legacy installations wait until enabled or
explicitly updated. Unavailable legacy folders remain listed and recoverable; reconnect
their disk or choose their current location. Once adopted, source edits require explicit
updates. Managed installations can keep running after their source disappears. If saved metadata
cannot be read, Vane stops restoration. Choose Update from Folder to validate and review
a replacement while retaining the known installation UUID; unreadable metadata is kept
as a local recovery file, and existing code files are retained.

### Disable, pin, or remove

**Disable** stops the context and closes its options/popup windows; it survives restart.
**Enable** validates accepted code and reuses its identity and approval, requesting review
if approval is missing or newly supported access is pending. Each profile has up to three
saved toolbar pins. Disabled or inactive installations retain their saved pin but show no
active toolbar control; unpin them to free a slot.

**Remove…** asks for confirmation, then clears installation metadata, approval, identity,
disabled state, pin, and Vane-owned code. It keeps the original source folder. Reinstalling
creates a new origin and cannot inherit old settings. Safari runtime IDs remain the
genuine signed identity; before a new Safari installation runs, Vane clears residual
WebKit extension storage for that identity in the owning profile. Removal is not a promise of
forensic erasure of WebKit-managed storage.

### Runtime access and diagnostics

Required installation access, optional declared access, and temporary/runtime grants
are separate sections. Optional capabilities/sites need a separate runtime request.
Additional grants expire at the displayed time or when the context reloads, is disabled,
or Vane quits; they are not permanent approval. `activeTab` can also grant temporary
active-page access after a user gesture, ending when that page navigates.

**Revoke Additional Access…** clears supported additional grants and denied requests,
including active-page user gestures. The extension may ask again. Required manifest
access stays approved: disable or remove the extension to stop all its access. Revocation
cannot undo past website changes. Pending requests fail closed on disable or removal.

**Copy Diagnostics** exports structured state, validated version fields, an installation
UUID, recognized capability names, and allowlisted error-domain/code information. It
excludes source paths, website targets, raw error messages, browsing content, credentials,
and extension storage. The detail view itself can show local paths and access patterns;
review anything shared separately from the copied diagnostic report.

### Compatibility and validation

Vane uses system WebKit WebExtension APIs. MV2/MV3 parsing does not guarantee that an
extension's APIs or real-site workflows work. The manager distinguishes capabilities
omitted by the installed WebKit parser from features without Vane host integration.

Declared keyboard commands run in eligible browser windows in their owning profile.
Browser and native editing shortcuts take precedence; details disclose conflicts.
Command/Control extension shortcuts can work in login fields. Character-insertion
shortcuts (including Option-only combinations) stay with native and detected website
editors. Commands do not run from sheets, private/locked tabs, or manager windows. WebKit supplies webpage extension context-menu items; Vane preserves them
alongside its link actions. Sidebar tab menus also include extension tab actions for the
clicked tab, including favourites and split panes. Bulk menus keep their core commands;
extension commands apply to the clicked row’s tab. Actions recheck the tab, profile,
private access and extension permission before dispatch. See
[sidebar menu behavior and validation](validation/sidebar-extension-menus.md).
Popup/options behavior still depends on the extension and WebKit.
Tab selection returns a clear error for rows hidden by folded folders, a collapsed
Pinned section, or a non-leading Split View pane. Activating those tabs remains supported.

Vane does not provide native messaging hosts, replacement browser pages, extension side
panels, developer-tools panels, omnibox keywords, or Chrome OAuth integration. Native
messaging has public WebKit hooks, but Vane has no approved host-execution mechanism.
ZIP/native-host feasibility, exact upstream package provenance, regression scope, and
assembled-app results are in [Extension validation](EXTENSION-VALIDATION.md). No Vane
backend or account is required.

Focused regression checks:

```sh
swift test --filter 'Extension.*Tests'
./.build/debug/vane selfcheck --pure
```

### Manifest V2 request filtering

MV2 background pages, content scripts, messaging, storage and actions can run.
System WebKit's `webRequest` cannot cancel or redirect requests or change headers,
even when it recognizes `webRequestBlocking`. Vane discloses that limitation.

For full **uBlock Origin** MV2, Vane can compile supported selected static lists,
enabled user filters and trusted-site settings into profile-isolated WebKit rules.
The extension must retain all website access. The manager shows active rule counts,
unsupported reasons or bridge failures. Changes apply after compilation; reload
changed pages. Disabling the extension also removes its compiled rules. This is
partial compatibility: dynamic filtering and other unrepresentable operations remain
unavailable. uBlock Origin Lite uses its existing MV3 declarative rules instead.
See [MV2 behavior, limits and browser research](MANIFEST-V2-COMPATIBILITY.md).

## Content blocking and filter subscriptions

Settings → Privacy and Security → Content Blocking separates **Import from Disk** (local
snapshots, never refreshed), **Link Local File** (explicit local refresh), and
**Subscribe by URL** (HTTPS lists). The built-in
starter list stays available offline. Existing imported snapshots and legacy file
references are preserved. Sources are shared across profiles; the main blocking switch
and site exceptions belong to each profile.

Case-sensitive URL rules (`$match-case`) are supported. Explicit positive resource sets can
exclude `script`, `image`, `stylesheet`, `font`, `media`, or `popup` with `~`; for example,
`$script,image,~image` applies only to scripts. Negative-only sets and exclusions of types
that WebKit combines into shared buckets remain unsupported and are reported.

### Linked local files

**Link Local File…** opts into reopening the chosen path every 30 seconds while Vane
runs, at startup, and after wake. Observation, security-scoped resolution, bounded reads,
and conversion run off the UI actor. Reopening the path handles editors that save by
atomic replacement and files that disappear and later return. Links are limited to 64
regular files, 8 MB each; symbolic links, pipes, devices, invalid UTF-8, HTML/error pages,
unbalanced conditionals and updates with no usable rules are rejected. The combined
policy retains its 64 MB, one-million-line and 64 KB-per-line admission bounds.

Each row exposes **Use these rules**, **Refresh automatically**, **Retry / Check Now**,
**Relink…**, **Unsupported Rules…**, and **Remove**. Pausing automatic refresh retains the
snapshot; pausing can save even when another source is unavailable. Disabling rules removes
that source from the active candidate and stops its automatic checks. Explicit Check Now still works while paused/disabled. Removal deletes
the owned snapshot and its access grant only after the remaining policy compiles.
Failures display in Settings and retain the accepted text. Repair the original path and
retry, or Relink when access has expired or moved. Reload open pages after an update.

Accepted text, diagnostics and status persist together in the `blockerLinkedSnapshots`
preferences document. The complete candidate, including other local sources, subscriptions
and profile exception variants, must compile under the shared source gate before a
changed snapshot is published. Compilation or persistence failure keeps the old policy.
The owned snapshots survive relaunch and are included in ordinary backups. File paths
and security-scoped bookmarks live separately in `LocalFilterSources`, outside the backup
owned-file allowlist; exporting/restoring a backup never carries a source access grant.
A restored snapshot with no existing local grant needs **Relink…** before it can refresh.
Import from Disk keeps its existing snapshot-only behavior.

### Additional EasyList syntax

Slash-delimited regex network filters support a deliberately conservative ASCII subset:
literals, escaped regex punctuation, `.`, alphanumeric/underscore character classes
(including same-category ranges such as `[0-9]` and negated classes), `?`, `+`, `*`, and
`^`/`$` only at the beginning/end. For example, `/\/ad[0-9]+\.js$/$script` blocks numbered
ad scripts. `$match-case`, resource restrictions and network exceptions also apply to
these regexes. Patterns are limited to 4096 characters. Groups, alternation, lookarounds,
backreferences, shorthand escapes (`\d`), counted or lazy quantifiers, and other regex
syntax remain unsupported and reported; they are never approximated. Matching uses
WebKit's canonical ASCII URL and defaults to case-insensitive matching.

The `$badfilter` preprocessing modifier discards its exact supported network-filter
counterpart across all source lists, including `@@` exception filters, without creating
a broad WebKit exception. For example, `/ad.js$script,badfilter` disables `/ad.js$script`
but leaves `/ad.js$image` and other overlapping blocks intact. Ordinary case-insensitive
patterns, supported first/third-party aliases and domain-list ordering are normalized;
`$match-case` patterns retain their case. Different EasyList resource types remain
distinct even when WebKit puts them in one bucket. This is whole-filter identity;
uBlock's special domain-list decomposition is not implemented. Unsupported target
options, repeated semantic options, duplicate `badfilter`, cosmetic variants
and conditional branches remain reported. A list containing only disabled/modifier rules
has no usable rules and cannot replace an accepted local/subscription source.

The subset follows [ABP regex syntax](https://help.adblockplus.org/adblock-plus-help-center/how-to-write-filters),
[WebKit's public regex grammar](https://webkit.org/blog/3476/content-blockers-first-look/),
and the [upstream badfilter definition](https://github.com/gorhill/uBlock/wiki/Static-filter-syntax#badfilter).
Real WebKit loopback fixtures verify matching/nonmatching regexes, case options, exact
badfilter removal, and overlapping blocks that must remain active, using ephemeral data
stores and no foreground window activation.

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
restrictions, ordinary CSS hiding, the safe regex subset and exact network `$badfilter`
preprocessing described above. Resource types follow WebKit's vocabulary:
subdocuments use `document`, and XHR/WebSocket/ping use `raw`. Other regex constructs, scriptlets,
procedural selectors, cosmetic exception variants, unknown options, mixed/invalid domain
restrictions, and rules inside conditional branches are skipped. Unbalanced conditional
directives reject a subscription update, and each source has independent preprocessing
state. **Unsupported Rules** reports totals by reason and the first 20 samples with line
numbers; local imports can be inspected separately. Vane does not claim full uBlock
Origin or AdGuard compatibility or expose request-by-request block counts.

Focused regression checks (including real WebKit network and cosmetic behavior):

```sh
python3 scripts/run-native-tests.py --jobs 1 --filter 'BlockerTests|BlockerLocalSourceTests|BlockerSubscriptionTests|BlockerWebKitTests'
./.build/debug/vane selfcheck --pure
```

## Site permissions

Camera, microphone, and location requests open a sheet on the requesting window with
**Allow Once**, **Always Allow**, and **Don’t Allow**. Location choices and the Location
row are available on macOS 26 and later. Allow Once belongs to the requesting
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

## AI connections and feature routing

Settings → Max lets you save multiple named connections, including several at the same
provider. Choose **Add Connection** for ChatGPT, Groq, OpenAI, OpenRouter, or an
OpenAI-compatible HTTPS API. Apple (on-device) is always available without an account.
Choose a connection separately for **Tab titles**, **Tab grouping**, **Download names**,
and **Page summaries**. Adding a connection does not change those routes. Existing
single-provider settings and saved keys migrate for naming/grouping; summaries stay
on-device until you explicitly choose a cloud connection for them.

Page summaries appear inside webpage link-hover cards. Enable **Settings → General →
Previews → Preview links on hover**, then pause over a link to another page. The card
shows the destination title, screenshot and description first; when Max is enabled
and the selected summary connection is available, a two-sentence summary follows.
Moving away, scrolling, clicking or pressing Escape dismisses the card. Cards stay
within their source pane and do not intercept page clicks. Battery Saver pauses
link previews. A failed or unavailable summary leaves the ordinary preview visible.

API-key connections take a model ID and your own key: choose **Save Key**, then
**Test Connection**. Groq defaults to `openai/gpt-oss-20b`. Custom providers need an HTTPS
base URL such as `https://api.example.com/v1` and JSON chat-completions support. Each
connection has separate credentials in local, non-synchronizing macOS Keychain items;
test data directories use separate namespaces. No key or token is bundled with Vane
or sent through a Vane server. Provider pricing and quotas apply.

For ChatGPT, choose **Continue with ChatGPT** and authorize Vane in your system browser.
Eligible accounts can grant access to their ChatGPT plan without an API key. Vane uses
OpenAI’s [public open-source sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source),
checks the returned signed identity and plan permission, and saves each registration's
issued client ID and credentials separately. After connecting, choose **Refresh Models**
and pick an available model, then assign features. **Manage Usage…** opens ChatGPT’s
usage settings. ChatGPT plan/workspace restrictions and shared usage limits apply.
Vane never automatically falls back to API-key billing. Reconnect to restore a revoked
session or authorize plan usage after declining it. **Sign Out** keeps the registration
for later reauthorization, attempts remote session revocation, and clears local tokens;
a warning identifies when remote revocation could not be confirmed.

Cloud naming/grouping sends titles, hostnames, and download naming metadata (source URL
path included, query strings/fragments excluded). Cloud summaries additionally send
bounded extracted page text when a link preview summarizes a page. These may contain
personal information. Private windows never use any of these cloud AI features;
assistant websites are separate and receive questions you send them even in private
windows. See the [privacy policy](../PRIVACY.md#ai-features). Requests are bounded and
cancellable. Errors and quotas keep the feature's ordinary non-AI fallback; no other
cloud connection is selected automatically.

**Remove Key** clears an API credential. **Remove Connection** clears that connection
and returns its feature routes to Apple. ChatGPT removal also attempts session revocation.

When AI and **Rename favorite and pinned tab titles** are enabled, right-click a pinned
tab and choose **Regenerate Title** to request a fresh name. A successful result replaces
the current name, including a manual rename, with the usual AI title reveal animation.
If generation fails, the current name stays. Tabs browsed away from their pinned page
are named from that pinned page's saved title.

Offline transport, OAuth, renewal and migration checks require no real account or key:

```sh
scripts/check-cloud-ai.sh
scripts/check-ai-connections.sh
scripts/check-ai-routing.sh
scripts/check-chatgpt.sh
scripts/check-chatgpt-session.sh
scripts/check-cloud-ai.sh --keychain # optional isolated local Keychain integration
```

## GitHub Live Folders

A Live Folder is a pinned folder of GitHub pull requests. Create one from a Space’s menu
with **New Live Folder…**. Choose pull requests you are involved in or one repository,
optionally restricted to recent activity. Refresh happens every five minutes, when
unfolded, or through **Refresh Now**. Taking a row out keeps it excluded.

A release with the optional OAuth client secret supports browser sign-in; ordinary
source builds use a personal access token. Native GitHub grants use generic-password
Keychain items scoped to the profile and data directory, separately from web passwords.
Owned legacy Internet-password tokens migrate only after the native value is stored;
their origin stays excluded from web autofill and password exports during migration.
Rejected credentials are retained for reconnection.

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
a web-flow OAuth grant. Renewal requires a release built with that optional secret.
For a live check, reconnect using such a release, quit/relaunch, and refresh after eight
hours:
the folder should renew automatically, and Console should record `[vane] GitHub OAuth
credential renewed` without requiring another sign-in.

## Favourite previews

GitHub, Gmail and Google Calendar favourites offer a hover card after a short pause. Move into the card to use its actions; move away or press Escape to dismiss. With keyboard focus on a favourite, press **⌥↓**, or choose **Show Favourite Preview** from its context menu or VoiceOver Actions. Items open in a new tab in the favourite’s profile. Gmail’s **Compose** opens its website compose flow and does not send a message.

Settings → Previews has a global favourite-preview switch and separate GitHub, Gmail and Calendar switches. These are independent of generic webpage link previews. A preview visits the normal website using the favourite’s profile session. It does not use Live Folders’ GitHub token, a Google API grant, cloud AI or a Vane server. No separate sign-in or API key is requested.

Content stays in a bounded memory cache, keyed by profile, account route and verified account identity. Repeat hovers reuse fresh data when the live favourite confirms that identity, or when the same route still has the authentication session under which its account was verified. Parked favourites do not need to reload the website for each hover. Cached content is invalidated on authentication-cookie changes, clearing site data, deleting a profile and changing preview preferences. No inbox or event content is logged or persisted by the preview subsystem. Private favourites show a fallback with website navigation actions.

Extraction depends on the website’s rendered markup. GitHub shows open PRs involving the signed-in user and review/check labels when available in the list. Gmail shows inbox subjects, senders and unread state. Calendar accepts only event links paired with explicit machine-readable times and supported meeting links; unrecognized schedules show **Preview unavailable** and **Open Site**. Unsupported layouts, partial results, missing account identity and failed loads are never reported as an empty inbox or calendar. Closing the card starts no new requests; an already-started request may finish within its eight-second deadline to fill the memory cache for a quick return. Foreground loads allow at most one restart if session cookies change. A single app-wide warmup waits 12 seconds after launch/activation and runs at most once every five minutes, checking up to three supported favourites in the visible key window, one at a time. It skips private, parked, minimized or obscured windows, disabled services, unsigned-in sessions, Battery Saver and inactive apps. Deactivation or Battery Saver cancels speculative work, while an adopted foreground request is preserved. Hidden pages are released after each request; no service page remains alive to poll. Previews collect at most 50 visible list rows from the current page and reveal them in batches of ten as you scroll without additional page loads. A failed request has a 30-second retry cooldown. A saved result whose refresh failed is labeled as stale.
