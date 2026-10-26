# Worker Engine Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether Safari 27 app-process selection also selects the extension worker's engine on macOS 26.

**Architecture:** The DEBUG signed diagnostic emits a bound background-process request only after its original UA failure, or its final successful MV3 comparison. The existing owned-process runner samples that exact PID read-only, validates its identity before and after, and acknowledges a bounded diagnostic hold. Keep the public-only reduction and product behavior unchanged.

**Tech Stack:** Swift/WebKit DEBUG diagnostics, Python standard library, Apple's sample/codesign/dwarfdump tools, GitHub Actions.

**Spec:** Local investigation record `/Users/nuh/.codex/artifacts/vane-mv3-upstream-2026-10-26/public-harness-audit-2026-10-26.md` (app-process image evidence does not attest worker images).

## Global Constraints

- macOS 26.0+ deployment floor; no bundled/forked WebKit, entitlement changes, UA rewriting, sleeps as a fix, weakened UA checks, or retries to green.
- Capture only after comparison; missing evidence is unavailable, never a UA pass. Preserve original failure and exact cleanup.
- Only the unregistered failing signed arm is dispatched for the new experiment. No ordinary passing suites.
- Existing user authorization to continue diagnosis applies; implement inline and obtain independent review.

## Review Focus

- PID reuse: revalidate app and backend executable/PID/kernel start before and after sampling; never signal a backend.
- Untrusted request: reject malformed/oversized/mismatched host, nonce, context, stage, or non-WebKit executable.
- Lifetime: hold the matched view/context at most thirty seconds after comparison; acknowledge even unavailable sampling so cleanup proceeds.
- Capture budget: sampling uses one26-second monotonic budget on a background thread; keep owner cancellation/timeout responsive. Verify installed image signatures and UUIDs offline after exit. Preserve system/older-engine observations before rejecting the staged expectation.
- Image attribution: require actual Binary Images entries and matched native page/process ownership; distinguish system/staged, verify staged UUIDs and Apple signatures.
- Timing: intermediate passing stages do not sample or add a roundtrip; the final passing stage is eligible only after every original assertion.

### Task 1: Bound capture and negative controls

**Files:** Create `scripts/worker-engine-evidence.py`, `scripts/test-worker-engine-evidence.py`; modify `scripts/check-extension-ua.py`.

**Interfaces:** `WorkerEngineCapture(data: Path, evidence: Path)` is an optional output observer called with output bytes, tracked app identity and identity reader. Capture JSON contains the request, app/backend identities, sampling status and parsed core images. Existing runner calls remain unchanged when disabled.

- [x] Write failing pure tests for request validation, PID replacement, unsupported targets, sample parsing, and missing/mixed image rejection.
- [x] Run `python3 -B scripts/test-worker-engine-evidence.py`; confirm failures before implementation.
- [x] Implement bounded sample capture, thirty-second acknowledgement protocol and staged-image verification. Use fixed system executables and bounded subprocess timeouts/output files.
- [x] Run the new pure tests; confirm all pass.

### Task 2: Native request and focused workflow

**Files:** Modify `Sources/Vane/ExtensionAppChecks.swift`, `.github/workflows/signed-extension-ua.yml`; refresh the reused runner blob binding in `.github/workflows/public-extension-ua.yml`.

**Interfaces:** Opt-in runner flag `--worker-engine` enables native `VANE_UA_CAPTURE_WORKER_ENGINE=1`. Native emits `UA WORKER ENGINE REQUEST ` plus JSON `{hostPID,pid,pidStart,nonce,context,stage,manifestVersion}`; runner creates `ua-worker-engine-<nonce>.done` in the exact isolated data directory. Guarded `WKProcessPool._webContentProcessInfo` enumerates only this app’s WebKit processes. Require exactly one entry marked `runningServiceWorkers`; a matching legacy background view must not resolve ambiguity. Preserve the registry inventory. The flag is connection metadata and does not establish worker liveness or context identity. Do not require a separate worker thread: pinned 624 and current SWServerWorker::workerThreadMode use UseMainThread when serviceWorkerPageIdentifier exists. Require the unique registry entry to contain the bound background view and agree with that view’s legacy PID, then verify kernel start and continuity.

- [x] Implement DEBUG-only post-comparison request/hold without changing UA assertions or intermediate success paths.
- [x] Add explicit workflow observer selection so only the failing unregistered arm runs; retain both as the ordinary default.
- [x] Build Vane; run focused new guard tests, workflow lint and diff checks.
- [x] Validate the capture on local task-owned signed Vane, verify exact process cleanup, and obtain independent review.
- [x] Push a `[skip ci]` commit; dispatch only the unregistered Safari 27 diagnostic once. Preserve the first failure and actual worker image evidence, or report unavailable evidence without a fix claim.

## Investigation result

Local capture attribution is unavailable. Legacy background PID and the unique app-scoped `runningServiceWorkers` entry both led to XPC/scavenger-only helpers. The complete app inventory excluded ambiguity; independent kernel thread names agreed with the sample. Preserve raw evidence and conditional attribution. No CI dispatch or fix claim until this measurement is useful. All tracked local test processes exited.

Independent review found and repaired two attribution guards: bind the native-observed kernel start in each PID request before any external reads, and require a capture for every executed trial so a missing decisive failure cannot be skipped. New pure negative tests failed before those repairs and pass afterward. Native kernel-start acquisition has build validation only; no additional native cohort was launched after the attribution discrepancy remained unresolved.

## Thread-mode correction

The idle-thread interpretation above was incorrect. An ordinary page repeatedly returned increasing counters from the reported PID while its sample showed only XPC/scavenger stacks. A busy-JavaScript control in that PID produced WebPage/JSC execution frames. Pinned 624 SWServerWorker.cpp429 and current upstream explicitly choose UseMainThread for page-backed workers. Therefore a separately named ServiceWorker thread is an invalid requirement for extension backgrounds. Correct capture instead requires a unique app-owned running-worker registry entry containing the bound background view, legacy view PID agreement, native-observed kernel start, external identity checks, and native context/view/PID/start continuity. This correction changes evidence acceptance only; all original UA assertions remain unchanged.

## Corrected local validation

`signed-local-27-main-thread-owner`: eight original four-stage UA comparisons passed and eight matched background-owner captures passed offline verification. All 32 tracked signing/app/cleanup/backend identities exited. All captures show system WebKit/WebCore/JSC22625.1.29.11.28. This is a finite local macOS27 result, not repair of the intermittent macOS26 failure. Swift build,32runner guards,6capture guards,actionlint and diff checks passed.

## First hosted capture result and bounded cold-tool repair

Run40349741697:8originalUAcomparisons pass; cleanup succeeds. First3captures time out after5seconds and therefore fail inspection. Trials4–8 record all3actual background-owner core images from stagedSafari21625.1.29.18.28 with identity/nativecontinuity records. This establishes observed worker-engine selection in those five passing trials, not the engine in a UA-failing trial or a UAfix. Symbolication is a plausible cold-tool bottleneck, not proven because old timeout handling dropped partial stdout/stderr. Capture timeout now preserves partial tool output, allows25seconds in a single26-second budget, and acknowledges within a30-second native hold. Original90-second primary bound and originalUAassertions remain unchanged. A new negative guard failed before partial-output preservation and passes afterward.
