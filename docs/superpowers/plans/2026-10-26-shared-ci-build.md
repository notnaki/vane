# Shared CI build and documentation checks

> **For agentic workers:** Implement inline with superpowers:executing-plans and obtain independent current-diff review.

**Goal:** Compile native products once per workflow, run common checks once, and give documentation-only changes a fast validation path.

**Architecture:** An Ubuntu change-scope job validates the diff and conservatively identifies documentation-only changes. App changes run source fixtures and one cached debug build. The build publishes a small runtime archive (app, XCTest bundle, resources, SwiftPM description) consumed by four isolated native runners and packaging. Every consumer verifies revision, checkout path, and toolchain before using the artifact; native tests retain preflight, coverage verification, and cleanup.

**Spec:** The user's requests in this chat to combine repeated build/setup work and avoid app checks for documentation such as SECURITY.md.

## Constraints and review focus

- Unknown paths, missing history, source-to-doc renames, workflow and test changes require app checks.
- The aggregate gate permits only intentional docs skips; failed, cancelled, missing, or unexpectedly skipped app checks fail.
- Only the debug build job reads/writes the Swift cache; no release credentials/products enter artifacts.
- Preserve executable permissions, bundle symlinks and resources, and require identical checkout root/revision/toolchain for SwiftPM's absolute paths.
- Keep UI runners isolated, retirement/fatal-signal checks intact, and existing application failures visible. The user has accepted unrelated app-test failures while CI infrastructure is verified.

## Tasks

- [x] Write scope CLI fixtures for docs-only, mixed/source/workflow changes, source renamed to Markdown, deleted Markdown, and missing/zero base revisions; watch failure, implement, and verify.
- [x] Write artifact roundtrip fixtures for minimal payload, executable/symlink preservation, mismatched revision/root/toolchain and unsafe paths; watch failure, implement, and verify. A real temporary SwiftPM package has already proven resource-aware XCTest discovery and execution from runtime-only files with the native build system.
- [x] Update workflow DAG and executable aggregate-gate tests: one debug compilation/bundle, immutable runtime upload, no shard rebuilds, common fixtures once, docs-only skips, and full failure propagation.
- [ ] Update contributor documentation; run focused fixtures and diff checks; push and create PR. Independently review the current head, validate a live shared-build matrix and a genuine docs-only PR run, fix infrastructure findings, and squash merge.
- [ ] Verify merge and archive only this task's worktree after verifying no task-owned app remains.
