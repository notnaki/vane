# Native Rendering Experiment Implementation Plan

> **For agentic workers:** Use the parallel-agent workflow for the independent domains below; the coordinator performs integration, serialized validation, and a fresh whole-diff review. This remains a default-off prototype.

**Goal:** Test all six user-approved native UI rendering opportunities on real websites without changing shipping defaults or regular browsing data.

**Architecture:** Preserve existing native owners, interaction state and WebKit documents. Add independently switchable paths that reduce repeated work, use compositor animation where appropriate, and pause unnecessary hidden work. Existing legacy paths remain available in the same binary.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WebKit, Core Animation, XCTest, Python diagnostics.

**Spec:** User-approved scope in chat; initial experiment architecture and comparison protocol in `docs/RENDER-EXPERIMENT.md`.

## Global Constraints

- Work only in the isolated `codex/render-performance-experiment` worktree. Do not merge it.
- Every candidate requires `VANE_RENDER_EXPERIMENT=1`; independent opt-outs must preserve attribution.
- Preserve animation semantics, live editor state, hover/press targets, accessibility, protection revocation, profile isolation, and retained WebKit identity.
- Respect system Reduce Motion and Battery Saver, including changes during travel.
- Never rasterize full sidebar document hosts or animate WebKit content by scaling text.
- The coordinator owns builds/profiling; workers must not compile while the real-site measurement window is active.
- Keep changes local until the combined diff has independent review and relevant validation.

## Review Focus

- Interrupting or reversing a panel transition must preserve the newest navigation intent and final geometry.
- Locking, deleting or replacing a cached row must revoke stale controls immediately, even when detached.
- Selection, rename, bulk selection counts, split-pane focus, and manual title/mute notifications must remain visible immediately.
- Hidden surfaces must refresh before exposure and must not present stale popovers, menus or editors.
- Appearance, backing scale and resizing must preserve texture size, clipping and sharp text.

## Task 1: Panel movement and WebKit viewport resize

**Files:** `Sources/Vane/LibrarySwipe.swift`; the `WebView`/`WebHost` region of `Sources/Vane/UI.swift` only if needed; new focused tests.

**Interfaces:** `RenderPerformanceExperiment.panelMotion`, `.deferredPageResize`; `EnvironmentValues.renderSurfaceActive` is supplied by the coordinator.

- [x] Inspect existing gesture width freezing and native layout counts before choosing a path.
- [x] Extend stable-surface motion to eligible programmatic panel/sidebar transitions, with bounded viewport resizing rather than per-frame WebKit reflow where feasible.
- [x] Set the retained Library panel's `renderSurfaceActive` value during exposure and travel.
- [x] Cover interruption, window resizing, final viewport size, policy changes and WebKit ownership.
- [x] Report focused test selectors and mechanism counts; coordinator runs them serially.

## Task 2: Selection and chrome observation

**Files:** `Sources/Vane/SidebarObservation.swift`, a new focused selection-observation file if needed, and sidebar-row/favourite/split regions of `Sources/Vane/UI.swift` after line 1400. Keep unrelated chrome and WebHost regions unchanged.

**Interface:** `RenderPerformanceExperiment.rowSelection`.

- [x] Identify all selection-dependent row surfaces and structural observers.
- [x] Narrow selection/rename updates so unchanged heavy row surfaces avoid work; keep affected old/new rows and changed bulk/split states correct.
- [x] Preserve authoritative closures/bindings and explicit metadata notifications; do not suppress changes using an incomplete property whitelist.
- [x] Add body/publication work-count tests plus rename, split, bulk-selection and accessibility regressions.

## Task 3: Native row-host reuse

**Files:** `Sources/Vane/NativeCachedSidebarBatches.swift`, `Sources/Vane/SidebarSectionRows.swift` if necessary, new focused tests.

**Interface:** `RenderPerformanceExperiment.hostReuse`.

- [x] Count redundant root replacements in the existing stable-owner cache.
- [x] Defer unnecessary detached-root refreshes or avoid provably redundant assignments, while refreshing before reattachment.
- [x] Immediately sanitize deleted/replaced/protected membership and preserve active interaction keepalives.
- [x] Cover late reattachment, content changes, locks, replacement objects, reorder and native readiness generations.

## Task 4: Hidden surfaces and GPU overdraw

**Files:** `Sources/Vane/LibraryWindow.swift`, `Sources/Vane/LibrarySpaceCatalog.swift` if needed, `Sources/Vane/ThemeWash.swift`, new focused files/tests. Do not edit LibrarySwipe or UI.swift.

**Interfaces:** `RenderPerformanceExperiment.hiddenSurfaces` and `EnvironmentValues.renderSurfaceActive`.

- [x] Inspect retained hidden panel subscriptions and identify work that can pause safely.
- [x] Pause avoidable hidden work without tearing down native controls; revalidate on exposure.
- [x] Evaluate a bounded compositor texture path for the static grain instead of repainting a window-sized pattern. Preserve appearance and tile scale; avoid indiscriminate extra layers.
- [x] Add visibility/exposure, appearance/backing-scale, pixel and work-count checks for retained changes.

**Outcome:** Hidden-work admission retained. Bounded grain compositor rejected
after mounted native pixel parity failed at both backing scales; original grain
renderer restored and candidate-specific source/tests preserved in temporary
diagnostic evidence. Closing admission now includes a cancellation-safe tail so
visible exiting content remains intact.

## Task 5: Integration, real-site validation and review

**Files:** shared experiment flags, launcher, `docs/RENDER-EXPERIMENT.md`, existing relevant tests.

- [x] Integrate each domain and keep independent launch modes/evidence flags complete.
- [x] Run a single combined focused native build/test pass; fix actionable regressions.
- [x] Validate on live Wikipedia, GitHub and MDN pages in disposable profiles, verifying requested host, expected title and nonempty content.
- [x] Compare candidates separately and together in a quiet profiling window. Exclude contaminated samples and distinguish callback cadence from presented FPS.
- [x] Obtain independent review of the final current diff and resolve findings.
- [x] Preserve the side branch and a reviewable draft; do not merge or touch regular Vane sessions.
- [x] Verify all task-owned native test processes exited; retain this active experiment worktree.

**Attribution outcome:** Combined eight-flag callback p95 regressed about 13–15% at 300 tabs across the three sites. Individual Wikipedia diagnostics admitted topology, layers, selection, viewport and hidden-work samples plus both legacy bookends. Signals, hosts and panels had no uncontaminated sample within two attempts; their timing remains unverified. No shipping promotion or presented-FPS claim.

**Preserved:** Draft PR https://github.com/notnaki/vane/pull/532 on `codex/render-performance-experiment`; not merged. Task-owned native hosts verified exited. Active managed experiment worktree retained.
