# Remaining performance wins implementation plan

**Goal:** Implement the five performance opportunities approved in chat: batch remaining archive paths, avoid identical Space metadata writes, index suspension membership checks, cache duplicate query scores, and initialize the history URL/date index.

**Architecture:** Reuse bulk archive persistence and completed sidebar mutations; capture membership sets once per synchronous sweep while retaining fresh post-await protection checks. Bound per-query title/URL score caching without changing ranking, and preserve disk comparison/failure semantics when skipping unchanged metadata.

**Tech stack:** Swift 6, AppKit, Combine, SQLite, XCTest. macOS 26+.

**Spec:** User-approved audit and “do those” in this thread.

## Constraints and review focus

- Preserve private/profile separation, locked folders, shared windows, stashed Space identity, archive order, split selection, and page retirement.
- Preserve fresh media/draft/ownership checks across asynchronous suspension probes.
- Preserve fuzzy/Unicode matching, per-visit popularity, and query cancellation; cap cache memory.
- Identical metadata skips must not hide corrupt/missing/foreign records or stale failure warnings.
- Add the history index for existing profiles without losing visits or changing title selection.

## Tasks

- [x] Task 1: Regression tests for archive batching, Space deletion and sweep semantics; route both through batch persistence/removal with correct Space ownership.
- [x] Task 2: Regression tests for identical Space metadata persistence and repaired/missing/foreign data; skip redundant encoding/writes only for exact owned committed metadata.
- [x] Task 3: Regression tests for suspension identity membership and lifecycle changes; precompute sweep facts without weakening asynchronous revalidation.
- [x] Task 4: Regression tests for bounded query-local duplicate scoring, unchanged ranking, and index migration; implement cache and default URL/date index.
- [ ] Task 5: Run focused tests, pure selfcheck and broader suite; obtain independent review and fix findings.
- [ ] Task 6: Push PR, verify required CI and latest main, squash-merge, verify and clean up task-owned worktree/processes.

## Validation

Run new behavioral/work-count regressions against the baseline before implementation. Use the native test wrapper sequentially for affected suites, then full local native validation for these cross-cutting changes. Required PR CI remains the merge gate. Synthetic diagnostic timings are not app frame-rate claims.

## Evidence

- Baseline metadata: 11 tests, 2 expected no-op inode failures; native cleanup passed.
- Baseline archive/index: 7 tests, expected batching/selection and missing-index failures; existing duplicate-ranking contracts passed; native cleanup passed.
- Integrated focused run: 40 tests passed, including byte-exact cache limits, ordinary/legacy schema migration, stash/shared archive behavior and suspension lifecycle checks; native cleanup verified 3 owned backends absent.
- Full native validation and independent review pending.
