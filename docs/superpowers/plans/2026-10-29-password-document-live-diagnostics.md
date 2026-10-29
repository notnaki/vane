# Password Document Live Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Observe real native navigation timing while the test host is alive, independently of SwiftPM output replay.

**Architecture:** A bounded private file channel publishes atomic, mode0600 phase records under an owned mode0700 directory. Each record is attributed to the canonical native runner's token and exact host launch. The supervisor polls this channel independently of buffered stdout and records source/receipt monotonic and wall timestamps.

**Tech Stack:** Swift/AppKit/WebKit/XCTest, Darwin openat/linkat, Python subprocess/libproc.

**Spec:** Root's approved diagnostic repair following run40932362264: private phase channel, monotonic and wall timing, actual1.2s pending navigation calibration, unchanged5s/security sequence. Evidence: password-macos26-preflight/remote-40932362264/independent-vector-audit.json.

## Global Constraints

- No production repair, Date deadline replacement, assertion weakening, deadline extension or skipped calibration.
- Preserve original in-place iframe removal → main username submit → password load security sequence.
- Keep the original7 remote vectors and prior evidence; append one pending-calibration arm last (8 attempts total). Aggregate remains unconditional failure.
- Native UI requires explicit ownership; exact host cleanup remains canonical runner responsibility.
- Default-nil DEBUG calibration gate delivers the real computed policy unchanged.
- Phase records: at most256, at most16384 bytes each, atomic publication, private regular files, no symlink traversal.
- Source/receipt clocks are both recorded; wall-clock adjustment versus main-actor starvation is a hypothesis to measure.

## Review Focus

- Native host exits between publication and reading: preserve provenance, never sample an unverified current launch.
- SwiftPM or console buffering: phase polling and sampler scheduling continue without forwarding stdout synchronously.
- Wrong token, sequence, owner, permissions, symlink or oversized record: explicit diagnostic failure.
- Calibration failure or missing policy callback: release any held completion, bound and join the release operation before fixture teardown.
- Failed sampling or missing required phase receipts: diagnostic run fails even when native driver exits0.

### Task1: Private phase reader and supervisor transport

**Files:** Create scripts/password-document-phases.py; modify scripts/password-document-preflight.py and scripts/test-password-document-preflight.py.

**Interfaces:** PhaseReader(directory:Path, token:str, runner, collector); poll() returns newly verified envelopes with receipt clocks; report() returns events/errors/valid. Context binds channelToken, nativeDirectory and nativeToken. Envelopes contain schema1, tokens, exact host, sequence, phase, source wallSeconds/monotonicNs and bounded scalar fields.

- [ ] Add failing behavioral tests for atomic live records, host attribution, symlink/mode/token/sequence/size/count rejection and late-source/receipt timestamp retention.
- [ ] Run tests and preserve actual assertion failures with a minimal no-op reader.
- [ ] Implement descriptor-based directory traversal and bounded reads; forward process/commit events to Collector using live receipt time.
- [ ] Poll phase channel independently of stdout; retain raw stdout only in native.log during the critical interval, emit bounded attempt summaries afterward.
- [ ] Require verified channel/phase validity in diagnostic result; run existing and new offline fixtures.

### Task2: Native phase publisher and clocks

**Files:** Create Tests/VaneTests/PasswordDocumentPhaseChannel.swift; modify PasswordAutofillTests.swift.

**Interfaces:** @MainActor PasswordDocumentPhaseChannel.init() throws; record(phase:String, fields:[String:Any]) records explicit failure. Validate the source's native environment/contract/manifest and exact PID/start/executable/bundle before writing. Atomic temporary file0600 → linkat publication → unlink temporary.

- [ ] Implement private-root traversal with O_NOFOLLOW on every component, token/manifest validation,256-record/16384-byte bounds and failure-preserving test reporting.
- [ ] Record state-getter entry/return, load-entry/return, wait-start with existing wall deadline, first predicate result, callback/commit, native selection and process receipts.
- [ ] Record DispatchTime uptime nanoseconds and Date seconds alongside supervisor receipt clocks; leave all condition/deadline semantics unchanged.
- [ ] Build tests without launching native/UI work.

### Task3: Real pending navigation calibration

**Files:** Modify Engine.swift, PasswordAutofillTests.swift and preflight calibration options.

**Interfaces:** DEBUG Tab.navigationDecisionDiagnosticGate receives the real WKNavigationAction and a no-argument delivery closure capturing the already-computed policy. Nil delivers normally. A scoped calibration stores only the exact password action's closure.

- [ ] Add pending-calibration mode using the original security test sequence and real SDK policy callback.
- [ ] Structured release waits at most2s for the callback, holds1.2s using a monotonic sleep, releases the exact policy and joins on success/failure before web/loop teardown.
- [ ] Require a live, identity-verified sampler start before commit plus recorded monotonic pending duration; keep original5s outcome wait.
- [ ] After explicit UI handoff, run one calibration and preserve every result, raw phase receipt and native host identity; no unchanged retry.
- [ ] Obtain independent current-diff review, address findings, commit scoped source, and give Root evidence for the next diagnostic-only remote preflight.

## Self-review

The file channel stays outside the canonical retirement directory because that protocol rejects unexpected files. All five review risks have explicit reader tests or mandatory native calibration checks. The new gate cannot change policy and is excluded from Release; it is scoped to one disposable tab. Timing is observed before any deadline change. Execution is inline as Root explicitly requested.
