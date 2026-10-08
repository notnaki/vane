# Content blocker updates implementation plan

**Goal:** Safely update URL subscriptions, explain conversion limits, and troubleshoot individual sites on macOS 27 using public WebKit APIs.

**Architecture:** Keep disk snapshots and legacy bookmarks unchanged. Persist subscriptions as an atomic versioned JSON document with accepted text and HTTP validators; validate the combined WebKit candidate before committing. Compile profile variants with exact top-level host exclusions and preserve last-good compilation on failures. A daily schedule checks on startup, wake, and hourly while running, with a one-hour failure backoff.

**Constraints:** Preserve user exceptions; never publish or persist unusable downloaded rules. No managed Apple entitlement or private API. Global filter sources, profile-scoped site exceptions; private exceptions stay in memory. Match existing UI motion policy.

**Review focus:** Invalid/HTML/oversized downloads; HTTP 304 without accepted source; failed storage after compilation; concurrent source changes; exception matching across redirects, frames, and relaunch.

### Task 1: Conversion reporting
- [ ] Add tests for diagnostic reason counts and line samples, empty/comment handling, mixed and invalid domains, conditional directives.
- [ ] Run `swift test --filter BlockerTests` to observe missing behavior.
- [ ] Return bounded diagnostics with converted counts; reject ambiguous domain restrictions and conditional rules rather than broaden them.

### Task 2: Subscription transactions and schedule
- [ ] Test daily due checks, failure backoff, validators/304, invalid responses, persistence failures, and preservation of accepted text.
- [ ] Implement injectable fetch/validation/storage manager, atomic manifest, bounded downloads, serialized mutations, startup/wake/hourly updates and manual updates.
- [ ] Validate full combined candidate before persisting each source; refresh only after a successful commit.

### Task 3: Site exceptions and controls
- [ ] Test exact host/profile exception scope, persistent/private storage, and WebKit compilation of exception variants.
- [ ] Compile per-profile variants excluding top-level exception hosts from block and cosmetic rules; recover cached variants on startup failure.
- [ ] Add per-site toggle with reload, filter subscription controls/status/diagnostics and exception removal in Privacy settings.

### Task 4: Verification and integration
- [ ] Run debug build, focused blocker/WebKit/site-control tests, and pure selfcheck on macOS 27.
- [ ] Document supported syntax, subscriptions/scheduling, local imports, exceptions, and last-good behavior.
- [ ] Push a `codex/` branch, create and attach PR, obtain independent review of latest diff, fix actionable findings and re-review.
- [ ] Wait for required CI and approval/mergeability checks, squash-merge, verify squash commit. No task-owned app processes may remain.

The user explicitly authorized implementation and the full PR cycle; execute inline without a separate plan approval checkpoint.
