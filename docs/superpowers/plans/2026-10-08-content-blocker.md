# Content blocker updates implementation plan

**Goal:** Safely update URL subscriptions, explain conversion limits, and troubleshoot individual sites on macOS 27 using public WebKit APIs.

**Architecture:** Keep disk snapshots and legacy bookmarks unchanged. Persist subscriptions as an atomic versioned JSON document with accepted text and HTTP validators; validate the combined WebKit candidate before committing. Compile profile variants with exact top-level host exclusions and preserve last-good compilation on failures. A daily schedule checks on startup, wake, and hourly while running, with a one-hour failure backoff.

**Constraints:** Preserve user exceptions; never publish or persist unusable downloaded rules. No managed Apple entitlement or private API. Global filter sources, profile-scoped site exceptions; private exception preferences stay in memory; compiled variants use owned transient storage. Match existing UI motion policy.

**Review focus:** Invalid/HTML/oversized downloads; HTTP 304 without accepted source; failed storage after compilation; concurrent source changes; exception matching across redirects, frames, and relaunch.

### Task 1: Conversion reporting
- [x] Add tests for diagnostic reason counts and line samples, empty/comment handling, mixed and invalid domains, conditional directives.
- [x] Run `swift test --filter BlockerTests` to observe missing behavior.
- [x] Return bounded diagnostics with converted counts; reject ambiguous domain restrictions and conditional rules rather than broaden them.

### Task 2: Subscription transactions and schedule
- [x] Test daily due checks, failure backoff, validators/304, invalid responses, persistence failures, and preservation of accepted text.
- [x] Implement injectable fetch/validation/storage manager, atomic manifest, bounded downloads, serialized mutations, startup/wake/hourly updates and manual updates.
- [x] Validate full combined candidate before persisting each source; refresh only after a successful commit.

### Task 3: Site exceptions and controls
- [x] Test exact host/profile exception scope, persistent/private storage, and WebKit compilation of exception variants.
- [x] Compile per-profile variants excluding top-level exception hosts from block and cosmetic rules; recover cached variants on startup failure.
- [x] Add per-site toggle with reload, filter subscription controls/status/diagnostics and exception removal in Privacy settings.

### Task 4: Verification and integration
- [x] Run debug build, focused blocker/WebKit/site-control tests, and pure selfcheck on macOS 27.
- [x] Document supported syntax, subscriptions/scheduling, local imports, exceptions, and last-good behavior.
- [ ] Push a `codex/` branch, create and attach PR, obtain independent review of latest diff, fix actionable findings and re-review.
- [ ] Wait for required CI and approval/mergeability checks, squash-merge, verify squash commit. No task-owned app processes may remain.

The user explicitly authorized implementation and the full PR cycle; execute inline without a separate plan approval checkpoint.

Independent review of 09e3741 identified four findings. Fixes add transient private-rule storage with process-owner locks and crash cleanup; an atomic accepted-base snapshot for exception changes when sources fail; separate preprocessing state per source and rejection of unbalanced downloads; and a bounded import success dialog opening a scrolling report. Added regression tests cover each finding. Updated diff must receive independent review and required CI before merging.
