# iCloud sync for Vane

Status: approved by the user on 2026-11-10, including download-history-only sync.

## Intent and decisions

The user wants iCloud sync for everything, with toggles for all categories. They
asked the agent to choose the design, explain it, and obtain approval before
building. The user approved the proposal below after excluding downloaded files.
The user subsequently specified that download history should sync, but downloaded
files must not sync. This exclusion is an explicit requirement.

Opening Vane on a second Mac should bring over the user's organized browser,
saved work, and chosen preferences. Ordinary browsing must keep working offline.
No Vane account or Vane-operated server is introduced. Use the Mac's Apple Account.

This is one substantial project. Deliver the complete approved category set;
implementation may use internal milestones, but foundational sync alone is not
the finished feature.

## Controls and scope

Add Settings → iCloud with a master switch, category switches, Sync Now, last
successful sync, current activity, storage/error information, and other Macs.
Master sync starts off. Setup shows the exact categories before any upload, with
Select All and individual switches. Choices are local to each Mac and never
changed by incoming preferences. Both sending and receiving require that Mac's
category switch. Changes to switches invalidate pending work before publication.

Each item separated by a semicolon in the table is its own toggle. Splitting
categories this way lets someone sync bookmarks without history, passwords
without API keys, or article links without downloading their offline content.

| Toggles | What follows the user | Initially selected in setup |
| --- | --- | --- |
| Profiles; Spaces | Names, colors, ordering and portable identity | Yes |
| Favourites; pinned tabs; sidebar folders | URLs, custom names, order, nesting and folder protection state | Yes |
| Bookmarks | Pages, titles and bookmark folders | Yes |
| Open tabs; recently closed tabs | Device-labelled page lists and their profile/Space association | Yes |
| History | Visits and titles, including existing local history | No |
| Easels | Boards, notes, drawings, saved captures and live-page URLs | Yes |
| Reading queue; offline article content | Saved article metadata/read state; separately, saved text and images | Yes |
| Space templates | Portable template contents | Yes |
| Boosts | Styles, Zap rules and scripts as saved content | Yes |
| Appearance; Reader preferences; search and homepage; keyboard shortcuts; other portable preferences | Explicitly allowlisted settings, not the entire preferences domain | Yes |
| Site settings; content blocking | Portable per-site choices; subscription URLs, custom rules and owned list content | Yes |
| Extensions; extension sync data | Installation sources/portable packages; WebExtension storage.sync | Yes |
| Passwords | Vane-owned saved website logins through iCloud Keychain | No |
| AI API keys | Vane-owned provider keys through iCloud Keychain | No |
| Download history | Completed-download metadata, including source URL, display filename, size, date and owning Mac; no file bytes or local destination grants | Yes |

Select All includes sensitive categories. The setup review must say plainly that
this includes browsing history, passwords and API keys. An individual category
can subsequently be disabled independently. There is no downloaded-file sync
option, including under Select All.

Device-specific and unavailable data are explained next to the controls, rather
than presented as working sync options. Private browsing never enters sync.
Cookies, website login sessions, WebKit local storage, cache, passkeys held by
websites/system credential providers, open form contents, active media,
downloaded files, and in-progress downloads stay with their owning device.
Website sign-ins may need to be repeated. Local paths/security-scoped bookmarks, biometric unlock proofs,
certificate exceptions, macOS permissions, extension grants, window coordinates,
updater state and crash-recovery internals also stay local.

GitHub Live Folder definitions sync with their owning sidebar folders; GitHub
authentication remains per Mac. Its rotating token pair must not be copied between
independent clients. Connection controls on the second Mac offer Sign In Again.
The same rule applies to extension storage.local/session and extension-managed
vaults: sync storage.sync, and let each extension handle its account/vault login.
This boundary is part of the requested approval, not a promise to clone a Mac.

## Visible behavior

First enable creates a local recovery point and merges existing local data with
iCloud; it never silently replaces either library. Profiles retain UUID identity;
the fixed default profile merges with the fixed default profile. Other profiles
remain distinct even if their names match. Empty fresh-install starter Spaces
may be suppressed only when proven untouched. Bookmarks deduplicate by canonical
serialized URL within a profile, retaining a deterministic surviving identity.

Tabs from other Macs appear in an Other Macs view with Open and Open All actions.
They do not automatically navigate, close, or steal focus from this Mac's tabs.
Closing a tab changes its owning device's list. Shared pinned/favourite entries
remain shared library objects. Local navigation state, back/forward stacks and
unsaved forms are not recreated remotely.

Turning a category off stops its uploads and application of downloads; existing
local and iCloud copies remain. Turning it back on reconciles with the last
acknowledged baseline: observed local edits/deletions are changes, while an item
never downloaded is not a deletion. Clear browsing history propagates only while
history sync is enabled, with wording explaining that effect.

Remove iCloud Data is a separate, explicitly confirmed action showing affected
categories; it pauses all this Mac's sync first. Account-wide reset markers
prevent another Mac from silently restoring removed cloud data. Other Macs pause
the affected categories when they observe the reset and require deliberate
re-enablement. Local copies remain. Keychain-backed categories have separate
removal wording because their service and guarantees differ.

Opening synced executable content must not inherit execution permission: Boost
scripts arrive disabled; extensions are verified/staged and require this Mac's
consent before activation. Safari extensions must be installed from their host
app here. Unpacked/owned packages can transfer as bounded inert assets, never as
trusted code. Locked folders arrive locked and use this Mac's authentication;
incoming changes cannot unlock them. Transfers of large saved assets show
progress and errors and never block ordinary browsing. Synced download-history
rows identify their owning Mac. Open/Reveal actions require this Mac's actual
local download record and file grant; remote metadata must never imply the file
is available locally or match a local file merely by its display filename. Local
destination paths, file grants and download resume data are not synchronized.

## Architecture and consistency

Keep the existing SQLite, JSON/session and Keychain stores as the local data
sources. Add a durable sync journal, category adapters, stable portable IDs,
deletion markers, acknowledged baselines, account namespace and schema versions.
Capture mutations only after local persistence succeeds. Imports, restore,
profile deletion and shutdown participate in the same ordering barriers as
interactive changes. Applying remote changes cannot create echo mutations.

Use CloudKit's private database with CKSyncEngine for library and preference
records. Give independently toggled categories separate sync zones, with small
control records for reset/account coordination and opaque parent identities.
Persist engine state and outgoing mutations durably. Category/account generations
gate every asynchronous completion. Remote records, relationships and assets are
validated before applying. Unknown newer schemas pause that category and request
an update rather than delete or reinterpret data.

Use entity/field-level versions for independent edits and stable identities for
ordered entries; never synchronize whole database or session files by replacement.
Causal edits supersede their predecessors. Concurrent edits to the same scalar
use a deterministic logical-version/device-ID tie-break, not wall-clock order.
Concurrent deletion wins against edits to that same identity. Tombstones remain
until an explicit namespace reset; old devices cannot resurrect deleted objects.
Parent deletion covers descendants, even when a child category is disabled.
Do not transfer child data when its category is off. For child-only sync, exchange
the minimum opaque parent identity and materialize a local placeholder context;
names/colors belong to the separately enabled parent category.

Concurrent edits to complex Easel content preserve a conflict copy rather than
discard either board. Assets are immutable, content-addressed, bounded and
validated; publish references only when their dependencies are available. Quota
and oversize failures stay visible and retryable, with no silent omission.
Concrete bounds and transfer batching are builder decisions, documented in the
implementation plan and UI before implementation; existing local import/security
bounds must not be weakened.

Passwords and AI keys use synchronizable, correctly access-group-scoped Keychain
items, independently of CloudKit. Opt-in migration keeps local originals until
verified success and handles pre-existing cloud items without overwriting an
unresolved credential conflict. Keychain refresh observes remote changes without
logging secrets. A disabled category stops Vane's cloud reads/writes and uses a
local snapshot; it cannot pause Apple's background transport for an already
synchronizable item. Say this explicitly. Removing cloud copies is a separate
explicit action, never an incidental effect of turning a switch off.

An Apple Account change immediately pauses all sync and quarantines old-account
queues/state. Preserve the local library. Resuming with a different account needs
an explicit choice to merge that local library; never automatically upload the
previous account's data. CloudKit and Keychain identity/availability must each be
checked; one being available does not prove the other is ready.

Use CloudKit encrypted fields and assets for browsing content, keeping only
minimal opaque routing information outside encrypted payloads. Do not claim
unconditional end-to-end encryption for CloudKit; Apple's Advanced Data Protection
changes key availability. Secrets never go into CloudKit records or diagnostic
logs. No third-party analytics or backend is introduced.

## Apple setup, validation, and completion

Provision an iCloud container for Vane's bundle ID and configure the app's signing,
Keychain access group, CloudKit environment and remote notifications appropriately.
Keep ad-hoc/local builds usable with sync visibly unavailable when the required
entitlements are absent. Never ship placeholder entitlements or claim live sync
without a provisioned build. Production schema deployment is an explicit dependency.
Follow the repository release policy before any release operation.

Test deterministic merging, duplicate import, deletes, concurrent moves/edits,
category combinations, parent/child switches, stale callbacks, retries, quota,
crash recovery, account changes, resets and Keychain migration/conflicts using
injected stores/transports. Verify UI responsiveness, Reduce Motion, Battery Saver,
private-mode exclusion, permissions and executable-content consent. Keep test
accounts and fixtures separate from the user's real library and secrets.

Validate properly signed service access and production transport behavior with
isolated journals: first merge, edits, persisted cursors, deletion and cloud removal.
On 11 November 2026 the user explicitly removed unavailable second-Mac hardware
from the merge gate. Cross-Mac convergence, offline/restart propagation and Keychain
propagation remain unverified follow-up coverage, not merge or release blockers.
If a second Mac becomes available, use a dedicated account for the full category,
lifecycle, large-asset and account-switch matrix. Never report that coverage as passed
based on single-Mac evidence. Provisioning and schema verification remain required.
Update privacy policy, data guides and feature/limitations claims to match verified
behavior. Then run the repository's validation, independent review and PR/merge
workflow. A release is not included merely by approving this design.

## Primary references

- [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [Apple sync engine sample](https://github.com/apple/sample-cloudkit-sync-engine)
- [Apple encrypted record fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)
- [Apple synchronizable Keychain items](https://developer.apple.com/documentation/security/ksecattrsynchronizable)

## Approval recorded

The user approved the complete category set, per-Mac toggles and defaults, Other
Macs tab behavior, local-only boundaries, Apple-managed secret sync, and
merge/deletion/reset rules above. Downloaded files are explicitly excluded.
