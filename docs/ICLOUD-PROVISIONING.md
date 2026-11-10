# Provisioning iCloud sync

Ordinary `make-app.sh` builds keep `Vane.entitlements` unchanged. They run with
sync unavailable. `ICloudKitTransport` examines the signed entitlements before
constructing any CloudKit container, including when asking for account status.

CloudKit requires an Apple Developer team, a registered explicit app identifier
`io.github.notnaki.vane`, and an actual CloudKit container assigned to that app.
Enable iCloud/CloudKit, Push Notifications and the app's own Keychain access group
in the developer portal. Create a macOS provisioning profile for the signing
certificate and those capabilities. Do not invent a container identifier or add
restricted entitlements to an ad-hoc signature.

To package an already provisioned developer build, supply the signing inputs:

```sh
SIGN_ID='certificate identity or SHA-1' \
VANE_ICLOUD_PROFILE='/absolute/path/to/profile.provisionprofile' \
VANE_ICLOUD_CONTAINER='the actual assigned iCloud container identifier' \
VANE_ICLOUD_ENVIRONMENT='Development' \
./make-app.sh debug
```

The packaging script checks profile expiration, exact app/team identity, platform,
CloudKit service/container/environment, push entitlement, Keychain group and the
selected signing certificate against the supplied profile. It embeds that profile
and generates restricted entitlements only from authorized values. The profile,
private signing key and generated entitlement file are local build inputs; never
commit them. An expired/revoked certificate or profile still requires Apple signing
verification; a successful local assembly alone does not establish service access.
Apple profiles can authorize all iCloud services and a team-scoped wildcard
Keychain group. The generator accepts those grants while emitting only CloudKit,
the explicitly assigned container, and Vane's exact Keychain group. It never copies
the wildcard to the executable. When the profile offers both CloudKit environments,
Development is the default; `VANE_ICLOUD_ENVIRONMENT` selects an explicitly authorized
environment. Ordinary ad-hoc builds remain unchanged.

Use a dedicated test Apple Account and two isolated Macs for cross-device validation.
Profiles and signing credentials are external inputs, never repository files.
The assigned container is `iCloud.io.github.notnaki.vane`. Its initial schema was
reviewed and deployed to Production on 10 November 2026. The exported
[schema](icloud-schema.ckdb) documents the encrypted fields and required index;
it contains no account data or credentials. A release remains a separate
policy-controlled task.

The release workflow requires `VANE_ICLOUD_PROFILE_BASE64` (the Developer ID
profile, not the development profile) as an Actions secret and
`VANE_ICLOUD_CONTAINER` as an Actions variable. It selects Production explicitly,
validates the profile against the imported signing identity, and removes the
temporary profile in its always-run cleanup. Both inputs were configured on
10 November 2026; no release was dispatched as part of setup.

The private database schema uses `VaneControl` and `VaneDeletionFence` records in `vane-control-v1` and
`VaneEntity` records in one opaque epoch-qualified custom zone per category. Control
records contain only schema and opaque namespace epochs. Entity payloads are stored
in a new encrypted `payload` field, with encrypted digest metadata; payloads above
256 KiB use the `asset` CKAsset field (CloudKit encrypts CKAssets by default).
New entity writes advertise payload schema 2, which preserves causally observed
re-creation after deletion. This client also reads legacy entity schema 1; older
clients reject schema 2 instead of dropping its birth versions. Control records,
ancestor fences, account envelopes and the local removal outbox retain schema 1.
Never configure `payload` as an ordinary unencrypted field in an existing schema.
No public database, server-side payload indexes or user-readable URL/title record
identifiers are used. Passwords and API keys use Keychain and cannot enter this
transport.

`VaneDeletionFence` records retain permanent opaque profile/Space deletion
identities, independently of their payload category switches. Their UUID-only
metadata uses encrypted `payload` and `digest` fields, with only `schema` outside
encryption. Querying this type needs CloudKit's record-name query index; no index
on encrypted fields is required. The client follows query cursors, validates at
most 100,000 fences and 4 KiB per fence, and saves at most 200 per batch. Fences
remain in the control zone when a category namespace is reset, so disabled child
categories cannot later resurrect a deleted ancestor. They remain scoped to the
private database of the explicitly selected Apple Account.

Bounds: 32 MiB per encoded entity/asset, 256 MiB per fetch/send cycle and at most 200
record modifications per batch. Oversize, quota, unknown-schema and partial service
failures remain visible and retain journal work. Assets are staged immutably under
hashed names and verified before decoding. Reset saves a fresh control epoch with
compare-and-swap semantics before deleting the old category zone. Devices that
observe a changed epoch pause the category before offering queued records.

Cloud-data removal keeps an account-bound local cleanup outbox in
`icloud-removals.json`. The journal fsyncs the selected old and replacement epochs
before advancing the server marker, and clears each receipt only after the old
zone's deletion is acknowledged. A failed CAS, network request, checkpoint or app
restart retains the same receipt; retry does not forget the old zone or rotate a
replacement epoch merely to report success. Earlier pending categories must also
finish before removal reports completion. Startup inspects this local metadata
without constructing a CloudKit container; unfinished cleanup stays visibly paused
until an explicit retry passes signing and original-account checks. Account mismatch
keeps the request pending and cannot delete another account's zones. The outbox
contains only account digests, categories and opaque UUID epochs, remains local,
and is bounded to 1 MiB and 1,024 receipts.

CloudKit encrypted fields do not imply unconditional end-to-end encryption.
Advanced Data Protection changes the availability of Apple's encryption keys.
See [Apple encrypted fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)
and [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5).

Keychain sync stores immutable causal revision metadata separately from removable
secret payload items. It uses synchronizable generic-password items, the explicit
application access group, the Data Protection Keychain and AfterFirstUnlock
accessibility. Bounds are 64 KiB per credential payload, 128 KiB per encoded causal
revision, 20,000 revisions per category and 4,096 small reset markers. Account
baseline records remain in the Keychain without synchronization. Reset epochs
fence revision queries before publishing or applying; verified replacement or
deletion removes superseded secret payloads while preserving causal metadata.
Concurrent conflicts retain their payloads. A payload awaiting Apple's propagation
is retryable and leaves the local original intact. Successful SecItem query and
readback establish local storage results; dedicated two-Mac Keychain propagation
and remote availability remain unverified.

The user explicitly accepted unavailable second-Mac verification as a documented
limitation on 11 November 2026. It is not a merge or release gate. Follow-up coverage
on two Macs should cover all categories, offline/restart/delete, switches, account
change, large assets, removal and Keychain propagation. No automated repository
test uses a real account; signed external service probes are recorded separately.

On 10 November 2026, signed development probes on one Mac verified account access,
encrypted payload and 300 KiB asset round trips, the deletion-fence query index,
and local add/read/delete of a synthetic synchronizable Keychain item. Test zones
and Keychain items were removed and probe processes exited. These service probes
do not prove cross-Mac propagation or all native adapter behavior. A signed harness
using verbatim production transport/model/journal sources also passed two-journal
create/fetch/edit/tombstone propagation in both Development and Production. Each
test-only namespace was inspected for exclusively known synthetic fixtures before
production removal reset its epoch and deleted the old zone. See
[validation evidence and limits](ICLOUD-VALIDATION.md).

Extension sync uses an unshown page created with the loaded context's public
`webViewConfiguration`. It calls only `storage.sync.get/set/remove`, after local
extension consent. A durable shadow retains pending values for inactive extensions;
unavailability is not interpreted as deletion. The public API offers no atomic
compare-and-swap across a vendor worker and no recall of already-submitted IPC.
Lease/admission checks reject new stale submissions; observed local changes and
readback are reconciled. The category starts off because extension-defined sync
values may include secrets that cannot be identified by arbitrary key names.

Older macOS WebKit bindings check the literal `__proto__` value as though it were
the object's prototype. Their native dictionary conversion can also invoke the
legacy setter and lose that key on reads. Vane's constant, unshown sync page handles
both: native assignments become own data properties in that page's realm, and a
rejected write temporarily scopes the page's `Object` binding to the dictionary
check. That binding is restored synchronously in `finally`, before awaiting IPC.
Actual object prototype chains and vendor page/worker realms are unchanged. Keys are
never renamed, no private storage APIs are used, and failures still retain pending
data. Native regression coverage requires literal-key round trips for strings,
numbers, booleans, null, arrays and nested objects, separate-page readback,
expected-value preservation, key-only removal and vendor-realm isolation.
Reference: [WebKit dictionary check](https://github.com/WebKit/WebKit/blob/de2d3ea41ff5d6c83696f3aedd1155dab8a0e1d5/Source/WebKit/WebProcess/Extensions/Bindings/JSWebExtensionWrapper.cpp#L558).
Public APIs also provide no atomic compare-and-swap against an extension worker;
an unobserved edit racing an already admitted write cannot be guaranteed to win.
The local shadow file has mode 0600 and remains local when sync is disabled.
Profile removal prunes its shadow at the next enabled inventory pass, not while
the category is off; retired profiles cannot be exported or revived on that pass.


Current AI integration syncs only registered API-key connections (Groq, OpenAI,
OpenRouter and custom HTTPS APIs). Their portable definitions and feature routes
belong to Portable preferences; API-key bytes require the separate, initially off
AI API keys switch and use iCloud Keychain. ChatGPT connections, registrations,
OAuth tokens and local ChatGPT feature routes never enter either payload. Unknown
remote API keys wait for their matching API definition; no unknown credential
account can overwrite a device-local ChatGPT credential. Damaged local connection
metadata fails closed rather than becoming an empty credential inventory. Applying
AI settings uses the current enabled binding and invalidates stale AI requests;
fresh installs retain the current default-off behavior.
