# Parallel native CI implementation plan

> **For agentic workers:** Implement inline using superpowers:executing-plans; request an independent whole-PR review.

**Goal:** Reduce native CI elapsed time by running four complete, disjoint test groups on isolated macOS runners.

**Architecture:** Discover tests from the built Swift bundle, keep each XCTest class together, and greedily distribute classes by recorded duration (with a per-test fallback for new classes). Each runner retains the existing preflight and retirement wrapper. Reject empty/malformed discovery, incomplete execution, and any failed matrix member.

**Tech Stack:** Python standard library, SwiftPM, GitHub Actions matrix.

**Spec:** The user's approved description in chat: balanced groups, isolated runners, independent cleanup, and complete test coverage.

## Global constraints

- Keep same-desktop test execution sequential; preserve existing deadlines and failure/signal checks.
- Preserve required `checks` gate, PR-safe caches, and one main-cache writer.
- Work on an isolated `codex/` branch; independent current-diff review, green required CI, squash merge, then archive this task's worktree.

## Review focus

- Newly added classes must be assigned automatically, exactly once.
- Empty or malformed discovery and missing completed tests must fail closed.
- A failed shard must not cancel the other runners or pass the aggregate gate.
- Cache writes and artifact names must remain safe across matrix members.
- Discovery, regex selection, and XCTest logs must agree on actual test identifiers.

### Task 1: Shard planning, execution verification, and CI integration

**Files:** Create `scripts/native-test-shards.py`, `scripts/test-native-test-shards.py`, `scripts/native-test-durations.json`; update `.github/workflows/checks.yml`, `scripts/test-checks-workflow.py`, and `README.md`.

**Interfaces:** `plan --inventory PATH --index N --count N --manifest PATH --filter-output PATH` writes the selected exact class regex and a JSON coverage manifest; `verify --manifest PATH --log PATH` rejects missing/incomplete test execution. Duration weights are advisory, never coverage selectors.

- [x] Write executable fixture tests for full/disjoint coverage, deterministic balance, new classes, invalid discovery/indices/weights, and missing/skipped/failed log cases; observe failure before implementation.
- [x] Implement the planner/verifier and duration estimates derived from Actions run 40315504860, then run fixture tests.
- [x] Convert native job to a four-member matrix with `fail-fast: false`; discover after test build, execute selected tests via the existing wrapper, verify completion, preserve per-shard artifacts, restrict cache writes to shard 1.
- [x] Update workflow regression fixtures and contributor instructions; run focused Python fixtures and diff checks. Replay the planner/verifier against a real native log to characterize identifiers.
- [ ] Commit, push, open PR, obtain independent review, fix actionable findings, and repeat relevant checks/review. Wait for current required CI and mergeability before squash merge.
- [ ] Verify merged SHA; inspect and archive only this task's worktree after verifying no owned app remains.

## Execution evidence

- Initial fixtures failed before implementation; six planner/verifier fixtures and 79 aggregate gate cases then passed, along with 37 retirement-driver fixtures and source/cache/release-policy fixtures.
- Replayed 2,126 historical native test identifiers with complete, disjoint assignment. Independent review of `3837953` found no actionable issues and a real SwiftPM probe verified discovery/filter/log identifier agreement.
- CI exposed the real bundle's early constructor diagnostic in SwiftPM discovery output. Added a failing regression before accepting only the exact successful bootstrap line; malformed identifiers, unsuccessful bootstrap diagnostics, and unknown output still fail closed. The actual preserved CI inventory contains 1,930 tests.
