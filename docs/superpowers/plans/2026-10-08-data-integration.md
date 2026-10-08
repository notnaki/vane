# Cross-feature data integration implementation plan

**Goal:** Verify documented backup, restart, isolation, and failure recovery behavior with synthetic data on macOS 27.

**Architecture:** Exercise the existing repositories and backup transaction together, using temporary directories and private defaults suites. Keep established storage formats and feature behavior. Fix only defects demonstrated by a failing regression.

**Constraints:** Coordinate compilation and native UI testing with the smoothness chat. Use `codex/data-integration`; never use the regular app's storage. Track and quit task-owned app processes. Incorporate the smoothness merge before final native verification. Follow independent review, required CI, and squash-merge.

1. Inspect existing feature and transaction coverage and documented scope.
2. Add a populated two-profile fixture containing templates, template-created Spaces, Easels with images, offline articles with resources/read state, Reader preferences, and origin-specific Boosts. Export, mutate/delete, restore through the launch path, reopen stores, and compare bytes and models.
3. Exercise every checkpoint of that populated restore, including durable commit. Verify exact originals/settings on rollback and the incoming inventory after commit. Check corrupt input and unavailable storage through the controller so feedback is asserted too.
4. Reproduce corrupt Boost preferences accepted by backup validation; add only the validation needed to reject those records before restore and preserve damaged originals in recovery.
5. Validate profile/private exclusions and existing atomic save failure tests. Document shared Reader preferences accurately.
6. After the smoothness merge, incorporate latest main, rerun focused tests, build the signed native app, and check populated backup/restore/restart, offline Reader, templates, Easels, Boosts, and feedback in isolated storage.
7. Refresh verified documentation/TODOs, open the PR, independently review its current diff, fix findings, wait for passing required CI, squash-merge, verify the merge, and quit all owned test instances.

**Review focus:** interrupted restore after nested article writes; settings restored alongside profile files; missing referenced Easels/images; private data reaching persistent repositories; damaged settings retained as recoverable evidence.

**Verified progress:** Steps 1–6 completed; evidence and native automation limits
are recorded in `docs/DATA-INTEGRATION.md`. The combined native restore/restart
used `8a271be` after smoothness merged as `b92602e`. All task-owned test processes
were stopped and disposable storage removed. Step 7's current-head reviews,
required CI and squash-merge are tracked in PR #339.
