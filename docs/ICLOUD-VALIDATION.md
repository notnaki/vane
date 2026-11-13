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

Disclosure now uses one sampled visibility clock for section extent, native row
positions, clipping and hit geometry, including nested reversals and equal-height
swaps. Settled completion rebases the sparse state without retaining replaced
tabs. Independent review identified two further issues: repeated descendant scans
per row, and capped large-folder rows painting past the shared section extent.
The final repair shares a sorted prefix index and frame query cache, and clips
the native section while shared disclosure is active. Resting overhang and the
direct-native fallback retain their existing behavior. New coverage includes
3,000-descendant work probes and a 300-child, 48-sample opening/reversal pixel and
hit-test fixture. Original disclosure samples, spacing and tolerances remain.

Fresh independent review of `0849402b` found no actionable issues. The exact
integrated tree built locally; entitlement, release-workflow, relocated-resource
and default-browser packaging fixtures passed. Hosted preflight
[43225580239](https://github.com/notnaki/vane/actions/runs/43225580239) uses one
revision/toolchain-verified runtime and three isolated native desktops, with every
outcome and cleanup receipt retained independently. All three attempts completed
586 tests (two skips each), with 67, 71 and 67 assertion failures respectively and
verified cleanup in every attempt. Eleven distinct cases failed across the three
attempts. All selected iCloud tests and the earlier first/cached page, click tint,
profile-colour and New Tab disclosure cases passed; this does not resolve the
newly exposed failures or replace protected integration CI.

The next diagnostic preflight narrows to the failed cases and related profile,
footer, disclosure, shadow and colour coverage. It tests release-velocity capture
before page preparation, immediate retargeting of already travelling profile
surfaces, native-density artwork comparison, admitted hover presentation, and one
bounded document-hidden readmission within the shadow fixture's existing
deadline. Disclosure and retained-viewport diagnostics preserve every original
outcome assertion and sample. These candidates remain unverified until their
hosted outcomes are retained; protected current-head PR CI remains pending.

Diagnostic run [43229519467](https://github.com/notnaki/vane/actions/runs/43229519467)
at `1ad3116c` completed three 67-case attempts, with five, six and six assertions
failing and verified cleanup throughout. Release velocity, early profile mount,
profile reversal and explicit footer-clock cases passed every attempt. The
shadow withdrawn-presentation case passed attempts one and two (1.527/1.595 s)
but failed attempt three; a same-turn ordering transition is insufficient and is
not a verified repair. The artwork density correction left two small-triangle
alpha comparisons failing at 1x. Large-folder diagnostics showed the footer
already offscreen at the scheduled clicks, and nested hit diagnostics showed a
visible child outside its native hosting owner's final bounds.

The next diagnostic changes native owner bounds to cover the shared sampled
extent and separates the fixture's slow setup motion from its unchanged sampled
outcome assertions. It also records artwork raster-density candidates. The
shadow candidate now observes native withdrawal and hidden WebKit visibility on
a later predicate before reappearing, retaining the exact document and original
five-second admission deadline. Its three 31-case attempts run in shadow-only
jobs, with separate desktops, logs and cleanup from the other native diagnostics.
Independent static review found no actionable issues; hosted outcomes remain
pending.

Run [43232637738](https://github.com/notnaki/vane/actions/runs/43232637738),
`043437b5`, retained three separate 31-case shadow attempts and three 37-case
native attempts. Shadow attempts two and three passed; attempt one failed
initial document admission, with cleanup verified for all three. Its trace
observed native withdrawal, then hidden document replies until a 2.865 s IPC
reply crossed the five-second deadline. The visibility event arrived around
5.955 s after initial hidden state. The attempted ordering recovery therefore
remains unverified.

The native owner-bounds correction passed nested moving-child hit coverage in
every attempt. Large-folder pixel and scheduled-click observations passed but
instant cleanup still coalesced its two endpoints; the next candidate observes
the first endpoint before reversing within the same ten-second wait. Raster
diagnostics isolated the small-triangle excess ink to 1x cached artwork; a 2x
cache sample met both existing alpha and pixel-difference tolerances. The next
tree uses a minimum 2x cache density, preserves logical geometry and retains the
48-case actual-window comparison. Target-click setup now admits a longer initial
leg while its interruption clicks retain production timing. Failure-only cover
retirement evidence and retained-viewport telemetry preserve outcome deadlines;
the latter restores the original short-circuit evaluation order.

The separately coordinated UI repair owns the next shadow-only preflight. Its
fixture blob `3ba156f1` requires a positive native compositor visibility
acknowledgement before the initial navigation, within the existing startup
admission budget; document and discovery deadlines remain unchanged. This branch
contains that exact public fixture file but launches no duplicate shadow jobs.
Its next three hosted attempts cover the broader native selection independently.

## Broader native follow-up, 12 November 2026

Run [43235158021](https://github.com/notnaki/vane/actions/runs/43235158021),
`f0ab4187`, completed three 556-test attempts, each with two skips and verified
cleanup. They failed with 26, 26 and 28 assertions respectively (one, one and two
unexpected failures). The minimum-2x artwork candidate introduced 23 failed
comparisons per attempt and is rejected. Large-folder settled cleanup failed in
all three; individual attempts additionally exposed fallback selection timing,
one New Tab opening sample, delayed velocity setup, and reverse-landing setup.
The selected iCloud tests passed throughout; this run is not a passing preflight.

Source analysis found that a non-nil shared disclosure sample outlived its
completion and retained closing rows indefinitely. The sample now carries an
explicit settled state through native configuration, including empty-delta
reversals. Structural updates retain the previous sampled visibility until the
first animated sample, while adopting the new baseline; this prevents a target
row pose appearing against the old footer extent. Pure regressions cover these
state transitions without changing the original native pixel or hit assertions.

The footer uses its actual backing density again. At 1x, opaque glyph artwork
receives its ink alpha during composition; at 2x, the original baked-alpha artwork
is retained. A standalone offscreen probe using the actual marker and symbol
views reproduced the low-density quantization and checked all 48 artwork cases
at both densities: zero failed cases with this candidate. The probe created no
NSApplication or windows. This is local raster evidence, not macOS 26 native
qualification; the original hosted comparisons remain required.

Fallback commit timing now observes the selected-space publisher's new value,
rather than inspecting old state during objectWillChange. The delayed-preparation
velocity regression supplies explicit event timestamps, isolating the intended
post-release delay from CI scheduling before release. Reverse-landing setup
admits an actually presented intermediate pose before release. Existing outcome
deadlines and tolerances remain unchanged.

The fixture-only `c1baa829` changes from PR #667 are integrated with these repairs:
exact profile backend retirement, fitted geometry, palette-above-preview ordering,
and a covered-then-live cancellation witness. Early profile cases retain one
owned AppKit loop each after resolving the overlapping helper changes. These
combined changes require fresh three-attempt hosted native validation.

Shadow qualification remains separately owned. The initial compositor gate at
blob `3ba156f1` failed one of three hosts at startup; explicit-display and window
animation candidates also failed. Run
[43240610066](https://github.com/notnaki/vane/actions/runs/43240610066) recorded an
onscreen, opaque, full-sized owned WindowServer surface while AppKit's occlusion
visible bit remained false. The animation candidate is rejected. No verified
shadow repair is claimed, and this branch dispatches no duplicate shadow jobs.

Run [43243600236](https://github.com/notnaki/vane/actions/runs/43243600236),
`17215ec7`, built successfully and completed three 559-test native attempts,
each with two skips and verified cleanup. Assertion counts were two, five and
two (one unexpected failure in each). Four distinct cases remained: large-folder
settled cleanup in every attempt, plus closing-row spacing, nested-folder overlap
and committed release velocity in attempt two. Footer artwork, the profile cases,
fallback selection timing and retained viewport checks passed all three. The
large-folder settlement candidate therefore did not repair its timeout; the run
is not a passing preflight. Astra's static review of the merged fixture changes
found no actionable issue before this run.

The next focused three-attempt preflight covers the failing disclosure/velocity
cases and related folder, New Tab, visibility-state and gesture tests. The native
velocity path now carries NSEvent timestamps into both tracking and release,
matching the gesture decision's input clock rather than measuring rendering time.
The original 20 ms flick exercises real monitor events; additional cases separate
150 ms delayed delivery from a 200 ms stationary event-time hold. The existing
100 ms stale-input limit and overshoot bounds remain unchanged. Independent
static review found no actionable issue; runtime qualification remains pending.

The disclosure follow-up keeps its shared coordinate frame and viewport travel
caps until the authoritative sample is settled, even when a content refresh
rebuilds rows without individual rollout metadata. An explicit disabled-animation
transaction can now settle its exact target without waiting for the interrupted
120-second setup curve; stale revisions cannot rebase a newer reversal. The
fallback native path starts admitted rows for one folder in one animation
transaction instead of separately yielded tasks. Detached rows withdraw their
start requests; unrelated opening refreshes retain their in-flight pose. New
coverage exercises cancellation, shared admission and opening-refresh spacing.
These changes retain every original native geometry and cleanup assertion.

A single coordinated incremental local build passed in 88.98 seconds with no
native test or app launch. It covered the event-clock repair and initial shared
layout/instant-settlement changes, before the final fallback-start addition;
it is not a build or native pass for that later addition. Hosted qualification
remains required for the complete candidate.

Run [43252553019](https://github.com/notnaki/vane/actions/runs/43252553019),
`59112fa3`, compiled and completed three 38-test focused attempts. Each retained
verified cleanup. Attempts one and two had two assertions (one unexpected);
attempt three had three assertions (one unexpected). All four native velocity
cases, eleven fallback rollout cases and the nested-folder reversal passed on
every host. Large-folder cleanup still timed out on all three; the original
New Tab disclosure case also failed on host three.

The new cleanup trace confirms the second resting collapse was requested, native
rows were reduced to one, clipping was released and settlement metadata was true,
while the interpolated sample still contained roughly 58–60 rows and the section
remained 2,360–2,475 points high. The explicit settlement callback therefore
worked but did not cancel the outer modifier's residual interpolation. This is
not a passing repair. The New Tab failure retained two late fractional child
positions exceeding the footer bound; those samples require investigation rather
than a tolerance change. Native tests remain hosted while resize owns the local
desktop/build reservation.

The follow-up normalizes a settled sample to its authoritative baseline count
and zero per-row deltas, then uses that same sample for the outer frame and
native environment. A regression supplies the recorded residual vector to a
settled basis while confirming active samples remain unchanged. Native sampled
row offsets also suppress inherited animation outside the offset modifier;
previous suppression wrapped only the row content inside it. This addresses a
source-supported second-animation hypothesis for the fractional New Tab pairs.
Overlap-only diagnostics now retain model/presentation positions and ancestor
animation keys if it recurs. All original samples, hits, tolerances and deadlines
remain unchanged; this candidate still needs hosted runtime qualification.

## Qualified focused repairs and final integration, 12 November 2026

Run [43257391641](https://github.com/notnaki/vane/actions/runs/43257391641),
`bb6ee95a`, built successfully and passed all 39 selected tests on each of three
macOS 26 ARM hosts, with zero failures, no skips and primary/cleanup status zero
throughout. Durations were 44.504, 43.092 and 45.330 seconds. The large-folder
trace now records the same settled endpoint on every host: one row, sampled
count one, height36, no retained rollout and no clipping. The original New Tab
pixel/hit assertions, nested reversal, fallback row spacing and all four velocity
cases passed unchanged. Independent Astra review found no actionable findings
in the final settlement/placement patch.

Separately owned shadow run
[43255828482](https://github.com/notnaki/vane/actions/runs/43255828482),
`7da25136`, passed a fresh withdrawn-window control and the complete 31-case
serial suite on each of three macOS 26 ARM hosts. All cleanup receipts were zero.
Suite durations were 41.879, 51.144 and 38.387 seconds. The exact public fixture
blob `5084d8f6d9a09fc8576aedb44a3070f15298da6c` is integrated here. It acquires
its AppKit lease before creating WebKit/window objects and uses WebKit's own
test-view occlusion policy for the three timer fixtures, checking the policy
getter. Exact native foreground/key/geometry admission and the real native
orderOut → hidden DOM → visible DOM boundary remain required, with the original
startup/document/outcome deadlines. No product setting changes. The logs confirm
both hidden transitions and successful discovery despite stale native occlusion
metadata. Earlier animation, deactivation and positive-occlusion-only candidates
remain rejected; the cancelled Intel characterization supplies no qualification.

The temporary auxiliary workflow is removed before updating PR #647. Focused
qualification supports proceeding to full protected CI for the combined tree;
it does not replace that final integration gate. Current main3882 is included,
and its separate checks/pages runs completed successfully before this update.

## Native motion admission follow-up, 12 November 2026

Full PR run [43264140732](https://github.com/notnaki/vane/actions/runs/43264140732)
on `74b2fc9c` failed one distinct case,
`NativeSidebarMotionTests.testDisabledTransactionMovesReorderedNativeRowImmediately`,
before the tested row mutation. Its independent 240 ms readiness sentinel was
first sampled at 768 ms; all eight samples were the endpoint85. Shard one
reported two assertions (one unexpected) and cleanup zero. Shards three/four
passed; shard two was cancelled by PR fail-fast. This was an unanticipated
failure, not a qualified full-CI result.

Diagnostic run [43268678915](https://github.com/notnaki/vane/actions/runs/43268678915)
on `5d11038c` added phase timestamps without changing behavior. Each of three
hosts passed 20 selected cases, with one existing system-Reduce-Motion skip and
primary/cleanup zero. Those prompt samples do not identify the source of the
original 768 ms delay or establish a repair.

Controlled regression run
[43273319049](https://github.com/notnaki/vane/actions/runs/43273319049), `bfc6731b`,
then reproduced two fixture defects as expected. Delaying the first observation
750 ms produced the same eight endpoint85 samples and failed admission. A real
presentation animation frozen at its interior position45 was wrongly accepted
by the old single-interior-sample predicate. The nonmoving endpoint control was
rejected correctly. Nine cases completed with one existing Reduce Motion skip,
three assertions across those two distinct failures, and cleanup zero.

The candidate keeps the independent readiness sentinel alive by autoreversing
its original 240 ms cycle during the original eight observations, with deferred
animation removal. Admission now requires both an interior position and actual
displacement across observations. The existing ten-second compatibility budget
is shared with sampling, never reset; the row mutation still begins afterward.
Original row-animation durations, samples, tolerances, owner checks and outcome
assertions remain unchanged. No product code changes.

Run [43277450579](https://github.com/notnaki/vane/actions/runs/43277450579),
`2ed35334`, passed the predetermined qualification on all three ARM hosts.
Each passed 23 related cases under the hosted policy (one existing Reduce Motion
skip), then all nine motion cases with Reduce Motion verified off, zero skips
and zero failures. Default-policy durations were 19.140, 14.371 and 13.730 seconds;
enabled-motion durations were 7.127, 6.376 and 5.890 seconds. All smoke, default
and enabled-motion primary/cleanup receipts were zero. Delayed observation now
witnessed real motion, while frozen-interior and nonmoving controls were rejected.
Independent Astra review found no actionable findings. The original scheduling
stall's underlying source remains unknown; the reproduced readiness-window
assumption is repaired rather than treating unchanged retries as a fix.

PR #667 merged as `ca9833ee`; its main checks43271177183 and pages43271176651
completed successfully before reconciliation. The merge retains the already
qualified fitted-width, currentSpaceID-publication, covered-then-live replay and
native retirement changes. Both early-profile entry points own exactly one
AppKit loop; the automatic merge's duplicate helper-level acquisition was
removed. The reconciled source tree is identical to the qualified candidate.
The temporary diagnostic workflow is removed before updating PR #647. Full
protected CI on this current-base integration remains required before merge.

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
