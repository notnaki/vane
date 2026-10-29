# Native CI boundary qualification

Main40774338406 at2f517f9 failed `NavigationWebKitTests.testPageLeavingForAnotherOriginKeepsItsSilentPopupBlock`: the popup attempt happened while the native URL was still the outgoing page, rather than the intended held destination. The raw worker-UA probe passed separately; that does not repair issue513 or the navigation failure. Preserve the original failure; do not retry unchanged code to establish success.

## Navigation scenario admission

- [x] Controlled RED: a2second exact-destination policy hold lets both old300ms popup timers run before any held destination request. The silent-Block case reproduces the original URL assertion shape; the adjacent destination-Allow case exposes missing scenario coverage. Primary1/cleanup0. This proves an ordering gap, not the exact historical CI latency mechanism.
- [x] Replace timer assumptions with exact held request/provisional URL/loading/outgoing-document admission. Page-load-owned interval callbacks consume native-written flags, so public JavaScript evaluation cannot donate a user gesture to the popup. Observe and forward one actual SDK callback with outgoing origin and gesture=false. Retain original popup/security assertions and single10second budget.
- [x] Four original/adversarial controls passed. Three predetermined fresh AppKit smokes and184-test cohorts passed:182passes+the same2 opt-in diagnostic skips per cohort, primary0/cleanup0 throughout.
- [x] Whole original shard4/current605-test cohort completed:583passes+22existing skips, all603 original methods plus2 controls verified, primary0/cleanup0. All recorded exact host identities exited. Independent source review found no actionable findings at navigation blob `e86d19d59c1617b6723aab9c98771577c6bd0397`.

Evidence is preserved under `ci-navigation-state-2f517f9` in the task artifact directory, including RED source/binary identity, source hashes, manifests, raw logs and final cleanup.

## Other concrete fixture gaps found by the shard audit

- [ ] Mount/pointer setup: exact row/trailing-control hit-test ownership and current viewport population must replace50/150/200ms setup guesses. Preserve inactive first-mouse behavior, action cadence, mounting bounds and early samples. Controlled clean/delayed attachment qualification is in progress in a separate checkout.
- [ ] Find/download cancellation: prove actual native search entry and held result, or exact late-download completion/cancellation acknowledgement, before negative assertions. Do not replace these with desired-result polling or longer sleeps. Scoped DEBUG boundaries must leave release behavior intact.
- [ ] Compose and independently review the current shipping diff, run the combined focused preflight, pass required CI integrated with latest main, squash-merge, and verify a fresh actual-main run. CI reliability is not marked repaired while this gate remains incomplete.

The audit's additional cases passed the failed main run; they are source-demonstrated validity gaps, not additional reproduced historical failures. Existing opt-in diagnostic/AX coverage limitations remain explicit and must not be counted as passes. No new skip, exclusion, relaxed assertion or outcome deadline is authorized.
