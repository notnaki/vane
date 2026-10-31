# Password username submission admission

The DEBUG native fixture `submitUsernameAndLoadPassword` previously assumed that
returning from JavaScript evaluation plus 100 ms meant the real `vanepw`
main-document username message had been processed. Evaluation completion does not
acknowledge the native password-step state write. This is a demonstrated fixture
ordering gap, separate from the unresolved original main b029274 continuation
navigation/commit stall.

## Change

One default-nil DEBUG delivery boundary runs after the existing SDK message,
main-frame, HTTPS, origin and web-view guards. Its received/processed/discarded
events contain profile/tab/web/document identities and a unique receipt ID, plus
the processed authorization Boolean. They expose no account, password or URL.
A held delivery is single-use and revalidates the exact live scope and origin.
Nil and Release product paths synchronously execute the original state write.

The DEBUG submission fixture now uses one monotonic five-second prerequisite
budget from before foreground/DOM submission. It waits for both JavaScript
completion and the matching native processed ACK, accepting a processed denial
as well as authorization. It rejects discarded/duplicate receipts and rechecks
the outgoing document and native presentation owner at the actual SDK navigation
request, including the same prerequisite deadline. The original continuation
navigation five-second wait and credential assertions are unchanged.

The root explicitly scoped this repair to DEBUG native CI. The non-DEBUG
release-test helper retains its previous 100 ms behavior so existing release-test
compilation remains valid; it is not qualified by this repair. Other existing
inline username-submit delays in the class are also outside this helper change.

## Predeclared qualification

Base: `8e32d0bd36d2c82014204c98d25d9650ec812334`, local macOS 27 / Swift 6.4,
native SwiftPM build backend. No unchanged native retry was run.

1. One RED pair against the old 100 ms helper: two fresh real SDK messages were
   held for 400 ms, covering main-selection authorization and embedded-selection
   denial. Both failed only the navigation-before-processing assertion (two
   expected assertion failures, zero unexpected). Each recorded received then
   discarded after navigation replaced the outgoing document. Primary 1,
   cleanup 0; both exact hosts exited and two owned backends were retired.
2. One GREEN pair after the ACK repair: two tests, no failures or skips. Both
   recorded received then processed before the password request, with actual
   authorization `true` and `false` respectively. Original password fill/denial
   assertions passed. Primary 0, cleanup 0; both exact hosts exited.
3. One complete `PasswordAutofillTests` class run on the identical GREEN source
   and binary: 52 tests, no failures or skips, primary 0 / cleanup 0; both exact
   hosts exited. Existing security and native-readiness tests were retained.

The initial build caught a missing actor annotation; the first GREEN build caught
the wrong JavaScript callback overload. Both compile failures are preserved and
launched no native hosts. Corrected builds passed. No product or test source was
changed during either GREEN native run. Independent source review cleared the
final Engine blob `eeb73df016afcaa8248e633fea0be421803e00aa` and test blob
`bc872a16eb84404adbaf3ebfb6674472e24fa9a3`.

Full logs, exact source snapshots/diffs, copied XCTest binaries, hashes, backend
retirement manifests and independently rechecked PID/start/path identities are
under `/Users/nuh/.codex/artifacts/vane-extension-repair-2026-10-28/password-submit-ack/`.
`aggregate.json` verifies all six owned launches exited and both GREEN runs used
identical sources and binary. This local qualification does not establish the
historical no-commit cause or authorize full CI or merging.
