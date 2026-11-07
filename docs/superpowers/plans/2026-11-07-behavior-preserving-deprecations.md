# Behavior-Preserving Deprecation Cleanup Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and independent review. Independent accessibility, raster, and WebKit adapter tasks may run in parallel; run shared native validation sequentially.

**Goal:** Replace deprecated APIs without changing Vane behavior or appearance.

**Architecture:** Use current public accessibility and image APIs, retaining eager rasterization and virtual accessibility nodes. Encapsulate the indispensable extension cache-policy process-pool implementation behind a narrow Objective-C compatibility owner. Keep private feature controls capability-checked.

**Tech Stack:** Swift 6, AppKit, WebKit, Objective-C, GitHub Actions.

**Spec:** User request following the codebase deprecation audit: fix all deprecated code without changing behavior or look; subagents and task decomposition authorized.

## Global Constraints

- Keep macOS 26 and Xcode 26 support, UI, animations, preferences, stored-data migrations, provider/model choices, and feature availability.
- Preserve two application-lifetime WebKit pool owners and extension resource revalidation. No public replacement exists for that private cache policy; retain only the documented adapter-local deprecated implementation.
- Preserve existing third-party AI request fields and OpenAI completion token budget.
- Do not change legacy payload diagnostics, privacy downsampling, image point sizes, raster scale, or accessibility navigation order.
- Implement, validate, obtain independent current-diff review, satisfy required CI, squash-merge, verify cleanup.

## Review Focus

- SwiftUI accessibility nodes may expose modern getters without formal protocol conformance; preserve their children, frames, and press actions.
- Block-based NSImage drawing must be materialized eagerly at the original display scale, with one raster representation.
- Missing/private preference setters and wrong signatures must fail safely without changing supported behavior.
- Extension-worker resource updates, separate profile stores, and geolocation fixture ownership must remain intact.
- Legacy URL-string-only NSError payloads and custom OpenAI-compatible endpoints must retain behavior.

### Task 1: Accessibility

- [x] Replace deprecated attribute/ignored/action calls in NativeSidebarNavigation and BufferedSidebarAccessibilityTests with public method-based access including informal modern nodes.
- [ ] Cover missing getters, selector-only nodes, typed frames/flags, actionability and navigation; run existing native sidebar/accessibility regressions.

### Task 2: Eager image rasterization

- [x] Replace three production and seven fixture lockFocus drawing sites with current drawing APIs preserving scale, pixels, serialization, orientation and lifetime.
- [x] Update explicit standalone compiler input lists if a shared raster helper is required; compare old/new raster behavior and run icon/minimized/locked-folder/Easel regressions.

### Task 3: WebKit adapters

- [x] Hide deprecated pool types from Swift behind an Objective-C owner without changing actual pool identity, cache configuration or ownership.
- [x] Replace unguarded private-preference KVC with signature-checked typed Boolean setters and cover supported/unavailable/mismatched capabilities.
- [ ] Run cold startup, extension ownership/update, permission, inspector and PiP regressions.

### Task 4: Request/configuration/compiler cleanup

- [x] Verify failing provider-payload regression, then replace OpenAI max_tokens with max_completion_tokens while retaining other providers.
- [x] Replace deprecated failing-URL symbol while preserving legacy NSError payloads; verify diagnostic regressions.
- [x] Upgrade download-artifact to Node24 action and update workflow fixture; keep integrity checks and runtime layout.
- [x] Correct existing test actor isolation and explicit closure captures without changing scheduling or lifetime semantics.

- [x] Remove retiring SwiftPM native-engine selection from active CI commands; support both native and current Swift Build product layouts in runtime artifacts. Keep historical validation evidence unchanged.

### Task 5: Validation and delivery

- [ ] Build app/tests, inspect remaining warnings, run focused and full required native validation, pure checks, standalone/packaging/workflow fixtures.
- [ ] Review current complete diff independently; fix findings and run appropriate checks.
- [ ] Push/open and link PR; satisfy current target CI and review requirements; squash-merge and preserve recovery ref before task-worktree cleanup.

## Execution Notes

- Prior audit app and test-target builds passed on d1c926ee with Swift 6.4/macOS 27; warnings identify the migration sites.
- Scope excludes speculative Observable migration, user-agent changes, and deleting old-data readers: each can change behavior and is not necessary for this cleanup.

- Default Swift 6.4/macOS 27 app and test build passed with no deprecated-declaration diagnostics. Seventeen focused adapter/raster/accessibility/reader tests passed, with primary and cleanup status 0.
- Independent old/new raster probes matched decoded sRGB pixels and shipped icon/backdrop/protection payload sizes. A synthetic fractional edge can use a higher-precision TIFF encoding while preserving decoded pixels and dimensions.
- OpenAI token-field tests failed before migration and passed afterward; third-party fields/budgets stayed unchanged. Workflow migration fixture failed before the action update and passed afterward.
- Workflow (8,227 gate cases), dual-layout artifact (12), native-runner fixture (38), resource packaging, release workflow, shard planning, and cold WebKit startup checks passed.
- Ruling: retain only the adapter-local process-pool deprecation exception because removing its resource-cache configuration breaks extension behavior.
- Ruling: explicitly retain the artifact action v5 digest-warning policy under v8; independent archive restoration checks remain unchanged.
