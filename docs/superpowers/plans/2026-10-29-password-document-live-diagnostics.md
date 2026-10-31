# Password Document Live Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Observe real native navigation timing while the test host is alive, independently of SwiftPM output replay.

**Architecture:** A bounded private file channel publishes atomic, mode0600 phase records under an owned mode0700 directory. Each record is attributed to the canonical native runner's token and exact host launch. The supervisor polls this channel independently of buffered stdout and records source/receipt monotonic and wall timestamps.

**Tech Stack:** Swift/AppKit/WebKit/XCTest, Darwin openat/linkat, Python subprocess/libproc.

**Spec:** Root's approved diagnostic repair following run40932362264: private phase channel, monotonic and wall timing, actual1.2s pending navigation calibration, unchanged5s/security sequence. Evidence: password-macos26-preflight/remote-40932362264/independent-vector-audit.json.

## Global Constraints

- No production repair, Date deadline replacement, assertion weakening, deadline extension or skipped calibration.
- Preserve original in-place iframe removal → main username submit → password load security sequence.
- Preserve the earlier7/8-attempt evidence. The next comparison has3 fresh-host arms: native-only414 prefix, ancestry-trace414 prefix, positive pending calibration. No retries; aggregate remains unconditional failure.
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

### Task4: Shipping-script observer-effect comparison

**Files:** Modify PasswordAutofillTests.swift, password-document-preflight.py/.json and its offline fixtures. No workflow edits.

**Interfaces:** Runtime script-provenance phase records the actual installed WKUserScript UTF-8 SHA256, compiled production Autofill.script SHA256, exact byte equality and injection attributes. verify_script_provenance(channel, control) validates native-only absence versus actual trace receipts. verify_username_step_receipt(channel) reports native message admission before password load independently of continuationAllowed.

- [ ] Add failing controls for wrong/missing installed hashes, unexpected native-only JS breadcrumbs and late/missing native main-username-step receipts; retain native XCTest outcome separately.
- [ ] Native-only skips only the ancestry rewrite and uses the normal production script. Both arms retain identical native clocks/channel/collector and Date5s/security sequence, including the existing100ms submission gap.
- [ ] Record SHA256 from the installed script and compiled production resource; require byte equality/zero ancestry receipts for native-only and distinct rewritten bytes/actual ancestry receipts for trace.
- [ ] Compare every actual native main-username-step receipt time with load-entry regardless of authority value; any late receipt makes admission incomplete. Bind receipts to the recorded chosen-applied outgoing document and separately assert observed continuationAllowed=false posthoc. Add no action wait/guard.
- [ ] Declare exactly one native-only prefix, one ancestry-trace prefix and one positive pending calibration on the same compiled macOS26 integration. Require the same production SHA across all3 and identical trace SHA between trace and calibration.

### Task5: Admit actual sampler progress before releasing the calibration

**Evidence and scope:** Run40948827683, integration6641abe, preserved under `password-macos26-preflight/remote-40948827683`, qualified both414-case prefixes with the original32 named skips and actual main-username-step receipts before load. Shipping script bytes/SHA matched exactly; trace/calibration bytes matched the independent rewrite. Password commit took96.964ms native-only and44.051ms with tracing. This sample shows no instrumentation effect and does not explain the original provisional-navigation stall. All six native hosts exited. The positive calibration correctly failed diagnostic validation: its real policy hold ended1257.970ms after load; native UI sampling progress was first observed1389.877ms after load. The sampler child existed during the hold, but existence was insufficient proof of sampling progress. This retained failure is the causal RED; do not repeat it unchanged.

**Design:** Keep the same real SDK action, computed policy, original Date5s navigation outcome, security sequence and DEBUG/default-nil production gate. Replace the calibration's fixed release interval with a private acknowledgment of real UI **and** getter-owned WebContent sampling progress. An absolute monotonic3s bound starts when the scoped calibration is constructed, including its callback-admission wait; absent/invalid/late acknowledgment fails explicitly and releases the captured policy once. Check this bound before accepting a ready acknowledgment. Do not observe/wait for document commit to release the policy. Join the structured release child before tab/window/loop teardown; the supervisor still cancels and reaps only its own sampler children.

**Transport and identity:** Worker progress goes to a bounded supervisor queue after positively identifying its actual `/usr/bin/sample` child and still-live sampled launch. The supervisor revalidates both roles, exact target PID/start/executable, exact sampler PID/start/executable, manifest-owned native host and navigation token before publishing one atomic mode0600 `samplers-ready.json` inside the existing mode0700, no-symlink channel. The file includes both channel/native tokens and the navigation token. The native consumer uses the already-open directory FD, bounded regular-file reads, typed decoding, fresh kernel identities and the tested WKWebView's actual content PID getter; wrong/missing/duplicate roles, token/identity mismatches, symlinks, stale proof or deadline expiry cannot release successfully. A native phase records accepted proof before policy delivery. File/count/queue limits and failures remain explicit.

**Implementation and controls:**

- [ ] Add a pure Foundation acknowledgment validator and offline executable tests against its actual Swift source, with injected identity observations only; no AppKit/XCTest host is launched. Cover valid two-role proof plus wrong tokens/roles/PID/start/path, absent/dead sampler/target, future/stale proof and bound violations. Compile errors do not count as RED.
- [ ] Add Python controls for incremental progress, no publication after one role, two-role revalidation, changed/dead launch refusal, bounded duplicate progress and private atomic-file protections. Retain old late-progress evidence as a negative verifier fixture.
- [ ] Deliver incremental progress through the bounded queue, publish once, consume/validate in the scoped gate and record acceptance. Require accepted proof plus both real progress records strictly before release in the posthoc verifier.
- [ ] Change only the frozen diagnostic vector to **one fresh target-only pending calibration**, once. Preserve both already-qualified prefix arms and all previous evidence; do not rerun either prefix. Keep workflow and unconditional aggregate failure unchanged.
- [ ] Run offline controls and source build, then independent review of the current diff. No local native/UI launch is planned. After review, push the scoped repair and perform exactly that one remote macOS26 calibration, preserving all results even on failure.
- [ ] Build and run offline fixtures only; obtain independent current-diff review before scoped commit/push to Draft556 under Root authorization. No local native launch is authorized for this comparison.

### Task6: Bounded pressure contrast to capture the original failure

Root approved investigation only: at most six fresh-host arms in fixed order **P414, direct target, P414, direct target, P414, direct target**, once on one pinned compiled macOS26 integration. Every arm uses the exact shipping WKUserScript bytes, without ancestry rewriting or the artificial policy hold. Swift/native code remains identical to5f97. Original within-document security sequence,100ms submit gap and Date5s outcome remain unchanged. The live private channel/sampler pipeline is qualified by40953824107; the prior finite shipping-versus-trace comparison40948827683 showed no effect in that sample, and the historical stall is still unexplained.

- [ ] Freeze six explicit single-repetition native-only vectors, preserve the exact original414 selection/execution-order hash and32 named prefix skips; require the target passes exactly once and reports actual matching main-step receipt before load separately from its authorization.
- [ ] After canonical retirement of the current arm, stop before any later arm on the first native failure, incomplete execution/scenario/diagnostic/provenance, changed named skip set or unverified retirement. Preserve the result and number of unstarted arms; no retry or automatic replacement. A checked-out revision change also stops before another launch.
- [ ] Add offline driver controls proving strict first/later failure stops, retained prior evidence, six-only ordered execution and capture-only reporting. No local UI/native run; Swift and workflow remain unchanged.
- [ ] Obtain independent current-diff review, scoped commit/push to556 under Root authorization, then preserve every attempted arm and analyze actual phase/stack/counter evidence. Stop further work after archived analysis for Root review.

Passing samples are capture outcomes, never repair qualification. Source clocks distinguish a long synchronous load/getter or predicate from pending navigation and wall-clock movement. Current sampling starts from the before-load process receipt: an earlier stall remains explicitly incomplete/phase-only evidence. The prior positive calibration proved live sampler startup and acknowledgment; its samplers were canceled at commit, so it did not establish completed symbolic stack collection. Keep the diagnostic workflow's aggregate failure unchanged; no full-CI/merge claim.
