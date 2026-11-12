# Native Space Regression Repair Plan

**Goal:** Explain and repair the 20 failures reproduced on main `3882bc9f`, retaining all 29 original cases as regression coverage.

**Approach:** Trace prepared-surface geometry, native ownership and compositor handoff before changing product behavior. Repair fixture inputs when they disagree with the rendered window; change product code only for a demonstrated product defect.

**Constraints:** Preserve outcome assertions and deadlines, owned-host/store cleanup, Reduce Motion and Battery Saver policy. Keep security and other task worktrees untouched. Serialize native work on the shared desktop. Original evidence is retained under `/private/tmp/vane-ui-rerun-20261112-e95a9f0c`.

- [ ] Compare claim-time widths and frames against idle preparation. Correct native gesture and colour fixtures to use the actual fitted window width; preserve narrow-window coverage.
- [ ] Reproduce remaining failures after the geometry correction. Investigate AppKit loop ownership, exact visible window, pointer, compositor ordering and presentation admission for each remaining case.
- [ ] Repair each demonstrated cause, retaining equivalent or stronger outcome checks and adding focused coverage where the original cases do not cover the cause.
- [ ] Run three predetermined serial passes of all 29 original cases, both complete affected classes and related readiness/width/theme tests. Preserve every attempt; a passing retry is not a repair.
- [ ] Obtain independent review, address findings and run full required CI on the current target integration.
- [ ] Squash-merge only after required checks/approvals and every main run finish. Verify all task-owned hosts exited and preserve evidence before worktree cleanup.

**Review focus:** Narrow windows versus saved widths; malformed viewport revocation; prepared layers above live content while search stays above previews; cancellation/reversal at the actual presented position; fixture teardown before application-loop shutdown.
