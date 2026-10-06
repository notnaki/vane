# Deprecation Modernization Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the current session and obtain an independent review before merging.

**Goal:** Replace deprecated APIs and outdated automation runtimes without changing Vane UI or UX.

**Architecture:** Use a shared, one-time nonpersistent WebKit initializer before registry queries. Centralize Foundation Models generation options behind an SDK-version compatibility branch. Keep all behavior, storage scopes, model sampling, and token budgets unchanged.

**Tech Stack:** Swift 6, macOS 26+, AppKit, WebKit, Foundation Models, GitHub Actions.

**Spec:** User request and AGENTS.md; audit recorded below.

## Global Constraints

- Minimum macOS version remains 26.0; Xcode 26 builds remain supported.
- No visible UI, interaction, animation, or preference changes.
- Preserve legacy stored-data migration code: it is compatibility code, not a deprecated API.
- Review latest PR commit, require successful CI, then squash-merge.

## Audit

Clean Xcode 27 debug build on latest main (58548a6):

| Finding | Replacement |
| --- | --- |
| Redundant unload listener in the injected editing-focus script | Existing pagehide listener, paired with pageshow to restore the same focused-field reporting after page-cache navigation |
| WKProcessPool initialization in Profiles.swift and BrowserChecks.swift | Shared WKWebsiteDataStore.nonPersistent initializer, verified in a cold process |
| Two GenerationOptions(sampling:) calls in AppleAI.swift | samplingMode initializer with FoundationModels module-version fallback for Xcode 26 |
| Async-alternative suggestion for WKWebExtensionTab.loadURL in smoke fixture | Call the concrete adapter's unchanged completion-handler implementation |
| Literal hide Selector construction | NSSelectorFromString because the inspector method is private SPI |
| Implicit optional-to-Any conversion in a page-script fixture | Explicit as Any cast; preserve optional boxing |
| Implicit strong outer captures followed by weak inner captures | Explicit strong outer capture; preserve existing weak Undo closure |
| Ambiguous first trailing closure in Downloads.swift fixture | Parenthesized first(where:) |
| Nonisolated DirectCapture initializer reads NSView.frame | Main-actor isolation for DirectCapture |
| checkout@v4 and cache@v4 runtime | Latest stable checkout@v7 and cache@v6 |

There are no external Swift package dependencies. Current zero-argument onChange closures are supported APIs. Default-browser, file-type, trust, and sharing code already use supported counterparts. Guarded WebKit inspector/PiP SPI has no equivalent public control API; retain it to preserve UX.

## Review Focus

- Cold registry queries must complete without creating a browser view.
- Registry preparation must not register a persistent profile or access the default store.
- Greedy AI sampling and token ceilings must remain identical on both SDK generations.
- PiP capture must keep its original geometry and run on the main actor.
- Workflow changes must preserve permissions, release triggers, full tag history, and restore-only PR caches.

## Tasks

- [x] Add a production WebKitStartup helper and a fresh-process harness that invokes it before fetching registry identifiers. Run the harness before implementation to confirm missing-symbol failure; implement using a cached Void initializer calling WKWebsiteDataStore.nonPersistent(). Wire both registry paths to prepare().
- [x] Add AppleAI.generationOptions(tokens:) using #if canImport(FoundationModels, _version: 2.0), preserving .greedy and maximumResponseTokens. Use it for structured and streaming responses.
- [x] Apply the warning-only syntax and actor changes listed in the audit, preserving the smoke fixture's existing completion-handler behavior.
- [x] Update checkout and restore/save cache actions to current stable majors; run workflow fixtures.
- [x] Remove the redundant injected unload listener and verify pagehide cleanup, pageshow restoration, and ordinary focus/blur reporting with a real-WebKit fixture.
- [ ] Run a clean warning-free build, pure checks, XCTest suite, cold-start harness, browser smoke, and helper packaging checks. Document pre-existing failures separately.
- [ ] Commit, push, open PR, obtain independent review, fix findings, verify required CI/approval state, squash-merge, and verify cleanup of owned test processes.

## Sources and compatibility decisions

- [Apple: WKProcessPool](https://developer.apple.com/documentation/webkit/wkprocesspool): multiple process pools no longer have an effect. Vane used the object only to initialize WebKit, so a transient nonpersistent data store replaces that role.
- [Apple: nonPersistent data store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()): stores data in memory without writing website data to disk.
- [Apple: GenerationOptions samplingMode initializer](https://developer.apple.com/documentation/foundationmodels/generationoptions/init(samplingmode:temperature:maximumresponsetokens:)): back-deployed before macOS 27. The installed SDK interface reports FoundationModels version 2.0; older SDKs need the previous initializer label. Both branches retain greedy sampling and the same token budget.
- [checkout releases](https://github.com/actions/checkout/releases/latest) and [cache releases](https://github.com/actions/cache/releases/latest): verified current stable versions v7.0.1 and v6.1.0. Both workflows use GitHub-hosted runners; their triggers and permissions are unchanged.

The Swift 6.4 compiler crashed generating the imported optional async loadURL bridge. The concrete Swift adapter's existing completion-handler method preserves the original fixture behavior and eliminates the importer suggestion without using that broken bridge. This is a fixture-only invocation change; production extension behavior is unchanged.

- [Apple: Safari event handling](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/HandlingEvents/HandlingEvents.html) marks unload deprecated in favor of pagehide. [WebKit page-cache lifecycle](https://webkit.org/blog/516/webkit-page-cache-ii-the-unload-event/) documents pagehide/pageshow for leaving and restoring a document. The existing pagehide callback already clears editing state; pageshow must restore it when WebKit reuses a cached document instead of reinjecting the script.

## Validation evidence

- Baseline latest-main build and 316 XCTest cases passed before implementation.
- Full production build with `-Xswiftc -warnings-as-errors` passed after all source changes.
- Existing 316 XCTest cases also passed with warnings treated as errors before the lifecycle regression was added.
- New cold-start harness failed before its production helper existed and passed after implementation.
- Editing lifecycle regression failed on the old unload registration and missing cached-document restore reporting; all 3 page-script tests passed after migration.
- Browser smoke passed 185 real-WebKit assertions and unregistered 12 temporary stores. Both owned process launches were tracked by bundle path, PID, and start time, then verified exited.
- App-icon and cloud-AI harnesses and both workflow fixtures passed.
- Final full XCTest and browser-smoke runs are repeated for the completed lifecycle change before merge.
