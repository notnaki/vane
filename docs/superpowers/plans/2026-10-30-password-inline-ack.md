# Inline password submission admission and latest-main qualification

After the scoped ACK and monotonic wait commits, three existing inline username
submissions still assumed that JavaScript evaluation plus 100 ms meant native
processing had completed: selected-account continuation, continuation consumption
after site focus, and revocation while a password-service read was held.

One shared test-only submission primitive now installs the scoped receipt
observer before the real DOM submission, awaits actual processing regardless of
authorization Boolean, and returns the same five-second admission ticket. Each
caller checks that ticket at the actual following SDK-request or held-service
release boundary. Its script parameter preserves the original JavaScript,
including revocation's insertion and submission of the second form. Revocation
adds no URL change or navigation.

The legacy selected-account scenario now uses the existing owned native fixture,
with its exact `login.example.test` origin, account data and assertions retained.
Default fixture origins are unchanged. The semaphore's original three-second
hold, ACK prerequisite five seconds, navigation/outcome deadlines and credential
assertions are retained. The service's actual wait result is recorded safely;
an already-completed read cannot masquerade as held, and retirement verifies a
real signal rather than a timeout.

Independent review also found that caller cancellation could skip the actual
service-lane drain and replace the primary error. Owned-read cleanup now signals
the read and awaits an uncancelled cleanup task through the real service barrier.
It preserves the primary error, reports secondary cleanup failure separately,
and propagates ordinary cancellation only after joining. Observers and delayed
deliveries are restored/joined before fixture/profile teardown.

The root explicitly retains the non-DEBUG release-test 100 ms fallback. This
qualification repairs DEBUG CI; it does not qualify that legacy release-test
assumption or alter Release product delivery behavior.

## Preserved controls and qualification

Clock repair `8b15837fc972ecfc731c1ec13740ad8bd62af976` was committed before a
normal clean merge of main `10c31ed1cda13d9b1f5d98caa967d555bee1edb6`, producing
base `ad6cd27097129c3f6fdaa86413e18a3619659230`. Local builds used macOS 27 /
Swift 6.4 and the native SwiftPM backend. No unchanged native retry was run.

Four separate controls hold a genuine SDK username message for 400 ms: main
selection, consumption, revocation during metadata read and revocation during
secret read. RED ran each selector in a separate fresh host, stopping the matrix
on missing fault admission or an unexpected result. Each old inline path reached
the actual following-action boundary with a matching received, still-unprocessed
message and failed one ordering assertion, primary 1 / cleanup 0, zero unexpected.
The controlled arm stops at that unmet prerequisite, joins its delivery, and
claims no later security outcome after failed admission. Both revocation arms
ran independently.

The first four GREEN controls passed 0 / 0. They remain observations with the
identified cancellation-cleanup gap, rather than final qualification. A separate
RED pair then exercised the actual old cleanup plus the metadata control. The
real `Passwords.perform` lane positively admitted an entered, still-pending read
before cancellation, with a deliberate 400 ms worker completion delay. Cleanup
replaced the primary error and returned before that read finished: two intended
assertion failures, zero unexpected, primary 1 / cleanup 0. The control explicitly
joined the read even against the broken helper.

After the cleanup repair, the final frozen source and binary passed:

1. The four held-message selectors separately, no failures or skips, each
   primary 0 / cleanup 0, followed by all original security assertions.
2. The cleanup/metadata pair, two tests, no failures or skips. Actual service
   admission, join before return and preservation of the primary error all held.
3. The complete `PasswordAutofillTests` class, 60 tests, no failures or skips,
   primary 0 / cleanup 0; 24 exact owned backends retired.
4. One latest-main integration cohort: the previously qualified 113
   Nav/Download/Find/sidebar/mount cases plus main 10c's 15 PageContextMenu and
   SpaceFooterMarker cases. All 128 passed without skips, primary 0 / cleanup 0;
   49 exact owned backends retired. The Password class was not repeated here.

All 32 exact host launches across the sixteen inline/cleanup/integration runs
were independently rechecked absent. Final runs used the identical copied XCTest
binary; the integration snapshot additionally froze 614 source/config files.
Full raw logs, finite plans, exact source snapshots/diffs, binaries/hashes,
retirement manifests and kernel PID/start/path checks are under
`/Users/nuh/.codex/artifacts/vane-extension-repair-2026-10-28/password-inline-ack/`.
Independent source review cleared final test blob
`7ff8ded2868c1c01369a10e03b4265126fb362de`.

These causal controls repair demonstrated submission and cleanup fixture defects.
The historical b029274 continuation no-commit cause remains unresolved. Full CI,
PR push and merge remain held for root coordination and latest-diff review.
