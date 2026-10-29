# Native CI boundary qualification

Main run 40774338406 at `2f517f9` failed `NavigationWebKitTests.testPageLeavingForAnotherOriginKeepsItsSilentPopupBlock`: after the popup attempt, the native URL still named the outgoing page rather than the intended held destination. The raw worker-UA probe passed separately; that does not repair issue 513 or the navigation failure. Preserve the original failure; do not retry unchanged code to establish success.

## Navigation scenario admission

- [x] Controlled RED: a 2-second exact-destination policy hold lets both old 300 ms popup timers run before any held destination request. The silent-Block case reproduces the original URL assertion shape; the adjacent destination-Allow case exposes missing scenario coverage. Primary 1 / cleanup 0. This proves an ordering gap, not the exact historical CI latency mechanism.
- [x] Replace timer assumptions with exact held-request, provisional-URL, loading and outgoing-document admission. Page-load-owned interval callbacks consume native-written flags, so public JavaScript evaluation cannot donate a user gesture to the popup. Observe and forward one actual SDK callback with outgoing origin and `gesture=false`. Retain the original popup/security assertions and single 10-second budget.
- [x] Four original/adversarial controls passed. Three predetermined fresh AppKit smokes and 184-test cohorts passed: 182 passes plus the same 2 opt-in diagnostic skips per cohort, primary 0 / cleanup 0 throughout.
- [x] Whole original shard 4 / current 605-test cohort completed: 583 passes plus 22 existing skips, all 603 original methods plus 2 controls verified, primary 0 / cleanup 0. All recorded exact host identities exited. Independent source review found no actionable findings at navigation blob `e86d19d59c1617b6723aab9c98771577c6bd0397`.

Original causal evidence is preserved under `ci-navigation-state-2f517f9` in the task artifact directory, including RED source/binary identity, source hashes, manifests, raw logs and final cleanup.

### Latest-main integration qualification

PR 551's first full required CI run, `40781844507`, passed. Main then advanced to `b029274da5bfcf7d673f28421fee0adf81b5022b` through PR 550, so strict protection required qualifying the integrated tree. The clean merge is `9587ee8976e94b0d76188c5d98717609f289ca91`; its reviewed navigation blob remains unchanged.

- [x] Predeclare three fresh AppKit launch smokes, each followed by the four original/delayed outgoing-page controls, then all tests in the changed target classes once. Preserve every attempt and stop on the first unexpected failure.
- [x] Native source/test build passed. All three smoke/control pairs passed: 3 smokes and 12 Nav-control executions, no skips, strict manifest verification and primary 0 / cleanup 0 throughout.
- [x] `FaviconPublicationTests`, `PinnedTabReturnTests` and `KeyboardAccessibilityTests` passed once: all 24 selected tests completed, no skips, primary 0 / cleanup 0.
- [x] Frozen source hashes remained unchanged throughout qualification. All 14 exact primary/cleanup host identities were independently verified absent before returning UI ownership to the mount investigation. No separate Vane app was launched.
- [ ] Independently review the latest integrated PR head and pass full required CI against the latest main before squash-merging. The earlier green run does not cover this integration.

The predeclared plan, source hashes, build output, exact manifests/filters, all seven raw native-run logs, wrapper invocations, process start identities and final cleanup check are preserved under `ci-navigation-integration-b029274` in the same task artifact directory. This qualification covers the new main integration; it does not identify the precise latency mechanism in the original failed run or resolve the independent fixture gaps below.

Actual-main run `40782819583` at `b029274` subsequently failed `PasswordAutofillTests.testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep` with a continuation/password-load timeout, primary 1 / cleanup 0. Its preserved log is `main-b029274-failure.log`. Passing navigation controls do not resolve that separate failure; its causal repair remains required before advancing full CI.

## Other concrete fixture gaps found by the shard audit

- [x] Mount/pointer setup: exact row/trailing-control hit-test ownership and current viewport population must replace50/150/200ms setup guesses. Preserve inactive first-mouse behavior, action cadence, mounting bounds and early samples. Controlled clean/delayed attachment qualification is preserved in the mount worktree and composed below.
- [x] Find/download cancellation: prove actual native search entry and held result, or exact late-download completion/cancellation acknowledgement, before negative assertions. Do not replace these with desired-result polling or longer sleeps. Scoped DEBUG boundaries must leave release behavior intact.
- [ ] Compose and independently review the current shipping diff, run the combined focused preflight, pass required CI integrated with latest main, squash-merge, and verify a fresh actual-main run. CI reliability is not marked repaired while this gate remains incomplete.

The audit's additional cases passed the failed main run; they are source-demonstrated validity gaps, not additional reproduced historical failures. Existing opt-in diagnostic/AX coverage limitations remain explicit and must not be counted as passes. No new skip, exclusion, relaxed assertion or outcome deadline is authorized.


## Composed source against main 426b53f

Integration `dade318a691850f8a76db0341791137c467669e2` combines navigation admission, callback completion barriers and mounted-sidebar prerequisites with main `426b53f`. Its 12-file diff received independent review with no actionable findings. The debug native build passed. One frozen affected-native cohort passed all 113 cases without skips, primary 0 / cleanup 0, and both exact hosts exited. Invocation, source/binary hashes, logs and retirement identities are retained under `ci-composed-dade318-native/` in the task artifact directory.

The callback controls reproduced three failing controls (four expected assertion failures) before the repair, then passed three fixed repetitions and the full 36-case Find/download cohort. The mount controls reproduced detached ownership, stale captured population and header-geometry gaps before their repairs. Three uncontaminated 24-case cohorts passed afterward; two additional passing cohorts overlapped another task and remain preserved but excluded from qualification. The exact original outcome deadlines, inactive first-mouse behavior, pointer cadence and early samples were retained. All recorded component hosts exited. The mounted snapshot observer and native result holders are default-nil DEBUG boundaries; release delivery is unchanged.

Full required CI remains held on the independent earlier password-document stall. Draft 556 now has reviewed private live phase transport and eight frozen macOS 26 diagnostic vectors, which passed native execution and diagnostic validity. The original-prefix target committed in about 146 milliseconds in that sample; this does not explain either the original failure or the prior eight-second successful Date-bound sample. The temporary diagnostic workflow is deliberately nonmergeable and is not part of this shipping diff. Main strict latest-integration `checks` and administrator enforcement remain enabled.
