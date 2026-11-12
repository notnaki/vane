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

## Current-main integration, 11 November 2026

The integration retains the approved sync boundaries alongside the current AI
connection, extension and browser APIs. Hosted macOS 26 preflight
[42975600166](https://github.com/notnaki/vane/actions/runs/42975600166) completed
177 iCloud tests in each of three attempts without an iCloud assertion failure.
That run also exposed pre-existing animated Space fixture failures when Reduce
Motion was explicitly disabled; it is not recorded as a passing overall suite.

The synthetic worker boundary probe needed explicit private-data access because
its isolated nonpersistent web view is private. Granting that access only to the
fixture context restored its original worker reply and all sync/local/session
separation assertions. The production extension permissions are unchanged.
The isolated hosted regression passed with verified cleanup in
[42974014280](https://github.com/notnaki/vane/actions/runs/42974014280).

The native fixture corrections establish owned AppKit loops and actual visible
owners, retire fixture windows before closing those loops, warm the cached page
before parking it, and compare the slide against live content while preserving
the palette above it. Early colour sampling now occurs at its original 100 ms
checkpoint. Sample counts, reversal limits, cancellation deadlines and pixel
bounds remain enforced. The fixture patch passed independent review.

The seven corrected animated Space cases passed together locally with zero
failures in 24.83 seconds and verified fixture retirement (`primary 0 / cleanup 0`).
The final fixture diff was independently reviewed without findings.

App/test-target builds, pure selfcheck, provisioning fixtures and AI routing
harnesses passed during integration. A full local native run was stopped at the
user's request and its original failures and successful cleanup were preserved;
it is not a full-suite pass. Full required PR CI remains mandatory before merge.

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

## PR repair validation, 12 November 2026

The repair integrates main through `5f6a2923`, retaining its current AI settings
layout and the optional iCloud API-key guidance. Separate unfinished animation
experiments remain preserved on their original branches.

Two account-admission regressions reproduced six failed assertions locally:
background credential edits could publish after an account switch, and account
notifications did not immediately pause sync. Background secret refreshes now
revalidate through the controller, and account notifications revoke admission
before another edit can be submitted. A deletion-only extension-storage update
also reproduced three failed assertions by creating a missing parent profile.
Only live values now create parents; tombstones retain validation and apply to
existing profiles without recreating absent ones.

The asynchronous shadow-discovery fixture now admits its exact visible window
and WebKit document before mutations. Its five-second outcome deadline and
original discovery/stale-target assertions are retained; DOM-only cases remain
unordered. The prior inactive-scheduling workaround is removed.

At `1d0b3892`, all 210 iCloud and shadow-autofill tests passed in each of three
local attempts, with primary and cleanup statuses both 0. The extension-storage
adapter's 13-test suite also passed after its deletion regression was observed
failing. Provisioning, release-workflow and update-channel fixtures passed.

Review then found that a local edit made after a credential snapshot could lose
its immediate follow-up while the controller still owned its active task. Its
regression failed before the controller gained a coalesced request, replayed only
after the active task clears. Revocation clears queued requests, and the next
pass revalidates the account. All 34 secret tests passed, including a queued edit
with a changed account. Compact Space fixtures now use their window's fitted
sidebar width for gestures and compositor fractions. The new compact-width,
click-tint and reversal selection passed after the original fraction/frame
assertions were observed failing. Independent review at `42e61f8f` found no
further actionable issues in these repairs.

A broader local attempt at `42e61f8f` completed 447 tests with one skip and ten
failed assertions across seven cases; cleanup passed. Another native XCTest
host overlapped this run on the shared desktop. Shadow discovery recorded a
visible but non-key window, an inactive app and a hidden WebKit document. This
is failed coverage, not a passing retry or proof that every failure had the same
cause. The failures remain recorded:

- `BoundedSidebarMountingTests.testSameHost127To129To127PreservesActiveRenameDraft`
- `KeyboardAccessibilityTests.testLittleAddressEndpointRemainsAvailableWithoutSidebar`
- `PasswordAutofillTests.testSelectedAccountCannotContinueIntoDifferentHiddenOrReadOnlyIdentity`
- `PasswordAutofillTests.testSubmittedMainUsernameAwaitsProcessedDenialBeforeNavigation`
- `PasswordShadowAutofillTests.testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation`
- `SpaceNativeRenderingTests.testCachedProfileChangesPageAtStartOfNativeLanding`
- `SpaceNativeRenderingTests.testSlowNativeSpaceLandingNeverReversesItsPresentation`

Hosted three-attempt native preflight
[43205593084](https://github.com/notnaki/vane/actions/runs/43205593084) checks
`42e61f8f` on an isolated macOS 26 desktop. The earlier
[43204799551](https://github.com/notnaki/vane/actions/runs/43204799551) checks
`ed210849`, before the queued-follow-up and fitted-width corrections. Both retain
all attempted outcomes. Hosted results and required current-head PR CI remain
integration gates.

## Normal-motion handoff and disclosure repairs, 12 November 2026

Hosted run [43205593084](https://github.com/notnaki/vane/actions/runs/43205593084)
confirmed that the fitted-width correction removed most geometry failures. Its
first two attempts completed with verified cleanup but remaining profile/motion
failures; the job deadline interrupted attempt three, whose cleanup is not
verified. The earlier `ed210849` run likewise retains two completed failed
attempts and a partial third attempt. Neither cancelled run counts as a pass.

The narrower three-attempt run
[43208252187](https://github.com/notnaki/vane/actions/runs/43208252187), at
`f8bb4aad`, completed every attempt and verified all cleanup. It retained six
distinct failing UI cases across its attempts: cached and first-visit page
handoffs, reverse-profile travel, click tint, parked-profile colour restoration,
and New Tab disclosure. Sync, credentials and shadow-autofill had no failures.
Its cached-page diagnostics showed a real active tab with no native superview,
while the window was key and the app active. This establishes a mount-order race
separately from the shared-desktop foreground failures.

A deterministic notification regression reproduced three failed assertions when
removing the arriving profile's input monitor aborted the source-owned cover.
The monitor now drops only its own input lease; explicit abort still cancels.
Four related tests then passed locally. A second real-compositor regression
reproduced a late-arriving wash at red 0.2114 while the source was already at
0.0921, outside the unchanged 0.03 tolerance. Joining the same native clock passed
all ten selected colour and ownership tests, with verified cleanup. Retained
wash layers do not gate completion of the two moving row surfaces.

Committed profile navigation now prepares only its destination under hidden
native roots while the source keeps window, footer, keyboard and page-lease
authority. Activation remains queued until the input action returns. The displayed
profile completes native layout before its curve starts; early page, colour and
footer observations retain their original 100 ms, 40 ms and 1000 ms checkpoints.
Window chrome observes profile metadata and save failures without repainting all
retained roots solely because the default active profile was persisted. Dedicated
coverage verifies hidden preparation cannot acquire the page lease or keyboard.

Independent review found that footer emphasis still discarded the newly shared
clock. Its explicit-clock regression reproduced a zero start. The repair retains
nonzero media time, converts it per marker layer, and seeds remaining-duration
tracking from that same start; legacy zero starts still begin at CA commit. Native
observations are captured before XCTest failure reporting, whose symbolication
was observed to block the main actor and consume later animation observations.

Profile fixtures now retire both visible and parked native roots before deleting
synthetic profile files. Reverse fixtures own their AppKit loop and admit their
exact visible owner before input. Memory-pressure coverage admits an existing
warm owner before applying relief and retains the original synchronous removal
assertion. The slow-swipe fixture retains all 35 samples, their 8 ms spacing and
its reversal/completion assertions; its explicit 200 ms landing fits the existing
280 ms minimum observation window, unlike the 300 ms product default. The repaired
slow-swipe case passed three local attempts with verified cleanup.

Disclosure repair and final integrated hosted/required CI remain pending. The
next preflight uses one revision/toolchain-verified runtime and three isolated
native desktops, with every outcome and cleanup receipt retained independently.

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
- The final combined tree must retain current-main integration, independent
  review and passing required CI before merge. Focused evidence does not replace
  the protected integration checks.
