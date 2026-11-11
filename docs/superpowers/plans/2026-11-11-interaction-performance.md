# Interaction performance

The user requested aggressive performance improvements and delegated selection of the work.
Preserve the Swift/WebKit architecture, page ownership, authentication, search ranking,
private/profile boundaries, motion policy and persisted data.

1. Measure repeated accessible-tab lookup and existing Store diagnostics in optimized builds.
2. Reuse folder protection membership while the ordered shapes and current authentication
   grants are unchanged. Skip filtering when nothing is blocked; compare canonical tab IDs
   directly when filtering is required. Cover edits, stashes, cycles, overlapping shapes,
   authentication changes and tab replacement without creating WebViews.
3. Aggregate matching visits per URL before limiting results, then recover each winning
   title with a bounded recent index probe and full scored-candidate fallback. Preserve best score, matching visit count,
   matching recency, bookmark priority, date/visit-ID title ties, fuzzy/Unicode/scoped
   matching and cancellation. Verify against explicit cases and a SQLite VM-work budget.
4. Run focused native checks, pure selfcheck, required CI and independent current-diff review.
   Squash-merge after the project gates pass, preserve the final head, and clean up this
   task's processes and worktree.

Performance diagnostics are opt-in; correctness checks carry no machine-sensitive budgets.

Reproduce the lookup diagnostic with an optimized debug build (the complete native test
target currently requires debug-only fixture hooks):

```sh
VANE_ACCESS_PERFORMANCE=1 python3 scripts/run-native-tests.py --jobs 2 -Xswiftc -O \
  --filter GeneralPerformanceTests/testRepeatedAccessibleTabLookupCosts
```

The initial measurements used a temporary release test manifest selecting only the
relevant tests and their unchanged native-host/retirement helpers. The ordinary manifest
must be restored before committing. An unmodified full release test target fails to
compile existing DownloadWebKit/WebDocumentTitle fixture hooks; that is separate from
the performance changes.

## Evidence so far

- Baseline lookup budget failed as expected: 200 lookups over 1,000 tabs took
  108–120 ms without protection and 117–123 ms with one protected tab. Ten full
  membership sweeps took 281–291 ms.
- Final folder-access implementation: 59 focused native tests passed; 200 lookups
  took 0.463 ms without protection and 33.056 ms with protection. Ten membership
  sweeps took 8.851 and 9.167 ms respectively. All fixture processes retired.
- Independent review found a malformed-parent mismatch between the bulk traversal
  and legacy Boolean ancestor checks. Added a conservative fallback and deterministic
  regression; native tests observed RED then GREEN. Final access review had no findings.
- Baseline suggestion work regression: all result assertions passed, but eight results
  from 40,000 matching visits required 5,092,000 SQLite VM instructions, failing the
  3,000,000-instruction budget.
- Query review identified an old-title workload that rescanned rejected visits.
  Added a bounded recent-title probe and scored-candidate fallback, plus sparse-history
  and older-best-score regressions. The production-source probe observed 1,120,000
  instructions before the fix and 520,000 afterward; 4,800 byte-exact original/current
  output comparisons passed. Final query review found no remaining actionable issues.
- Original 240,000-visit Store diagnostics: suggestion query 939–964 ms; History
  search 486–508 ms. History browse stayed under 1 ms. These are synthetic diagnostics,
  not page-load or rendered-frame measurements.

## Final local validation

- 67 focused optimized native tests passed, including all new regressions, folder locks,
  malformed shapes, search ranking, historical titles, Unicode, bookmarks and engine scope.
  Native wrapper primary/cleanup statuses were both zero, with all owned hosts retired.
- Dense suggestion work: 1,873,000 SQLite instructions for the original 5,092,000-instruction
  fixture. Sparse old-title work: 520,000 instructions, within the 750,000 budget.
- 240,000-visit suggestions: 632–650 ms (median 640.927 ms), versus the original
  939–964 ms (median 952.271 ms). Cancellation drained in 0.256 ms with no returned rows.
- Final 1,000-tab diagnostic: 200 accessible-tab lookups took 0.482 ms without locks and
  33.660 ms with one protected tab; ten membership sweeps took 8.378 and 9.046 ms.
- Release `selfcheck --pure` passed. The temporary test manifest was restored exactly.
- Independent access and suggestion reviews have no remaining actionable findings.

Required full CI and merge remain governed by the project PR workflow; PR checks are the
authoritative record of broader native integration validation.
