# iCloud validation evidence

The approved scope is every portable category with separate switches, including
download history and excluding downloaded file bytes, paths, grants and resume
data. Master sync starts off. History, extension sync values, passwords and AI
keys start unselected. Secrets use a separate synchronizable Keychain path.

## Local verification, 10 November 2026

- Focused native wrapper: 213 tests, one explicit Keychain opt-in skip, zero
  failures; separate retirement driver passed, primary and cleanup statuses both 0.
  Log: `vane-icloud-final-focused-wrapper-21.log` in the task's temporary evidence.
- The subsequent literal-key repair passed the same 213-test selection and fresh
  cleanup (`vane-icloud-proto-focused-22.log`). Its native test requires all six
  JSON value kinds, a fresh page reading the native value, stale expected-value
  preservation, removal of only that key, and an unchanged vendor-page realm.
  Before the fix, the strict test failed at the public dictionary check; the
  first experiment admitted writes but exposed six lost-readback assertions.
  Both original failures are retained alongside the final passing run.
- Provisioning generator: nine deterministic regressions passed, including
  legitimate Apple wildcard authorizations narrowed to exact executable grants,
  wrong certificate/team rejection and environment selection.
- Actual release workflow fixture: missing signing/provisioning inputs fail
  closed; profile restoration preserves exact bytes and mode 0600; malformed
  base64/container inputs fail; existing stable/nightly publication and tag
  ordering checks pass. No real release, tag or workflow was dispatched.
- Packaging: current debug executable assembled with the Developer ID Production
  profile; `codesign --verify --deep --strict` passed for the app and helpers.
- Workflow lint has one existing tool-version boundary: local actionlint does not
  recognize `concurrency.queue: max`. With only that existing diagnostic excluded,
  release workflow and shell lint pass. Serialization policy was preserved.

The entire native suite and hosted required checks have not run on the final
integration. Those gates remain required before merge; focused results do not
replace them.

## Signed service verification on one Mac

Team `T7X84HN3W3` assigned `iCloud.io.github.notnaki.vane` to Vane's existing app ID.
Matching Mac Development and Developer ID profiles were generated and validated
against their installed signing certificates. Profiles and private credentials
are external inputs and are not committed.

Signed development probes verified account availability, encrypted inline values,
a 300 KiB asset round trip, the deletion-fence record-name query index, and local
add/read/delete of a uniquely named synthetic synchronizable Keychain item.

A separate harness copied production transport, model, journal, apply-context and
removal sources verbatim. Only unrelated app-owner dependencies were stubbed.
With two independent journals it exercised real CKSyncEngine creation, fetch,
editing with a persisted cursor, and logical deletion. It passed against both
Development and Production after fixing initial sign-in admission and missing
server-record revisions after incremental fetches. This is transport evidence,
not proof of every native adapter or two physical devices.

Before removing fixture namespaces, cleanup enumerated every live row and
required its decoded identity to belong to the exact synthetic fixture allowlist.
It then used production removal to advance the epoch and delete the old zone.
Development cleanup verified two known rows; Production cleanup verified one.
All probe processes exited with recorded exact executable hashes, PIDs and times.
No regular browser app was launched and no user browser data was sent by probes.
Private run receipts, logs and source hashes are retained in the task's
`vane-icloud-provisioning-20261110` artifact directory.

The exported schema was reviewed and CloudKit Console confirmed deployment to
Production. The release profile secret and container variable were configured;
no signing private key was exported or changed for this task.

## Verification limits and remaining integration gates

- No second Mac is available. Cross-Mac convergence, offline/restart behavior
  across devices and iCloud Keychain propagation remain unverified. Existing
  Apple Account access is not evidence of a dedicated two-Mac test setup. The user
  explicitly accepted this limitation on 11 November 2026; it is not a merge or
  release gate.
- Public storage APIs have no atomic compare-and-swap against a vendor worker,
  and cannot recall admitted IPC. Observed late changes are reconciled; an
  unobserved race with an already submitted write has that platform boundary.
- Already admitted native/Keychain/CloudKit work can finish after revocation.
  Admission gates prevent new stale submissions; Apple controls propagation of
  items already marked synchronizable. The UI does not promise rollback.
- Local extension shadows remain while sync is off. Deleted profiles are pruned
  at the next enabled inventory pass and cannot be re-exported then; this is not
  an immediate physical purge when a profile is deleted with the category off.
- Final independent review and integration validation are still required. The
  current branch must use the coordinator's actual released base before its
  first push/full CI/merge; no CI capacity is reserved while blocked.
