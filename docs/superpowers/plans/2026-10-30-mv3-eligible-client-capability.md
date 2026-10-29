# MV3 Eligible Client Capability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement only capability A: determine whether this system runtime exposes the genuine SDK worker-hosting window in its eligible client set.

**Architecture:** An opt-in DEBUG CLI loads one fresh public SDK context without an explicit background load or private creation callback. Its own synthetic worker reads startup UA first, generates a worker-birth nonce second, queries eligible clients once, and signals completion through the public action badge containing that birth nonce. After a visible SDK popup supplies the original identity/UA verdict, a separately bound RPC reads the immutable query result. A signed normal-app driver validates the report and exact process/backend retirement.

**Tech Stack:** Swift, public macOS26+ WebKit/AppKit/Security, Python offline protocol tests.

**Spec:** Parent authorization2026-10-30 and source audit `/Users/nuh/.codex/artifacts/vane-extension-repair-2026-10-28/mv3-renewed-boundary-2026-10-29/audit-and-proposed-protocol.txt`; only capability A is authorized.

## Global Constraints

- System WebKit/macOS26+, no framework staging/fork, vendor rewriting, UA shim, added private callback or permission expansion.
- Label eligible client observations; never equate them with the initial UA lookup or complete origin-map membership.
- Exactly one context/app capability arm. No eight-trial cohort, native/UI launch, push or remote dispatch without Root coordination.
- Startup UA is read before nonce generation and query. Worker-birth nonce differs from later RPC request nonces.
- Empty/hidden/ambiguous hosting-client results are UNAVAILABLE and nonzero, never a passing UA repair.
- Original UA/identity verdict is recorded before reading client results; a mismatch remains FAILED regardless of observations.
- Keep profile/store/pool/controller/runtime/origin/manifest/namespace binding, a source fingerprint, OS/WebKit qualification and exact owned process cleanup.
- Existing password calibration and every other checkout/workflow remain untouched. All execution logs outside the checkout.

## Review Focus

- Forged/stale response nonces or namespace/runtime/origin values fail validation.
- UA mismatch cannot be converted to pass by eligible clients; unavailable cannot become pass.
- Hosting-client identity must be a unique top-level window at this fresh context's exact root, captured before another extension document exists.
- Missing callbacks/timeouts preserve the first failure and still require exact post-exit store retirement.
- Release binary contains no diagnostic CLI; the driver refuses staged-engine environment overrides and weak/unverified signing.

### Task1: Protocol validation and one-context DEBUG CLI

**Files:** new `Sources/Vane/ExtensionWorkerClientCapability.swift`; DEBUG route in `Sources/Vane/main.swift`; new `scripts/worker-client-capability.py`, `scripts/test-worker-client-capability.py`.

- [ ] Write offline report/claim validator tests first; preserve the missing-implementation RED. Cover success, failed UA, unavailable/empty/duplicate hosting clients, wrong origin/runtime/store/profile, reused birth/request nonce, missing original verdict, source hash/schema/type errors and unsafe report files.
- [ ] Implement the strict validator, then the public SDK CLI with the same schema and immutable worker result. No product host policy changes.
- [ ] Run offline tests and build DEBUG only; no native/UI execution under the other task's lease.

### Task2: Owned signed driver and review/preflight proposal

- [ ] Build one sandboxed/Hardened Runtime signed diagnostic app from the built binary, with immutable provenance/source hashes. Reuse existing exact kernel-start process identity helper and public named-store retirement approach.
- [ ] Add offline ownership/report negative controls; preserve RED→GREEN evidence. Driver runs at most one primary and one cleanup, refuses foreign native drivers or engine overrides, and retains all evidence on failure.
- [ ] Obtain independent current-diff review and address actionable findings before push or dispatch.
- [ ] Propose one manual macOS26 system-WebKit job: offline validators, build DEBUG, sign/verify, one capability arm, exact post-exit cleanup, upload all artifacts. No ordinary suite/unchanged retry or additional cohort. Await Root dispatch authorization.

## Execution ledger

- Base426b53f; managed checkout created through native tool; branch `codex/mv3-eligible-client-capability`. Other active worktrees preserved.
- Root explicitly selected inline source/build/offline execution. Native/UI baseline is intentionally deferred while dmg_reliability owns the lease.

## Focused CI proposal (not dispatched)

After Root approves the reviewed source and execution slot, add a dedicated diagnostic workflow triggered by one push to this exact diagnostic branch, with one `macos-26` job and a10-minute job bound. A new workflow need not already exist on the default branch for that push trigger. Do not use a dispatch-only workflow that GitHub has never registered, add a matrix, rerun an unchanged native failure, or run the eight-trial proposal. Review the workflow diff before the authorized push. This job is diagnostic and does not replace required latest-main CI.

Commands in that one job, without a restored build cache:

```sh
set -euo pipefail
sw_vers
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-worker-client-capability.py
node --check Tests/Diagnostics/WorkerClientCapability/worker.js
swift build --build-system native -c debug
PYTHONDONTWRITEBYTECODE=1 python3 scripts/worker-client-capability.py \
  --binary .build/out/Products/Debug/vane \
  --evidence-dir "$RUNNER_TEMP/mv3-client-capability/attempt-1" --run
```

Capture the command log outside the fresh `attempt-1` directory; upload that parent artifact directory with `if: always()`. No `continue-on-error`: UA mismatch exits1; hidden/empty/ambiguous eligible host exits3; only a fully bound observed result exits0. A cleanup failure remains nonzero. Preserve all native reports, the separately saved pre-result UA verdict, source/signature/runtime evidence, phase preflight snapshots, exact PID/kernel-start/path records and named-store absence proof. If the app or backend cannot be verified retired, retain its claim/directory and report the remaining identity instead of reporting cleanup success. Do not dispatch a second native arm without explaining and repairing an unexpected failure first.

The sole resulting claim is whether this exact qualified runtime exposes the fresh context's genuine hosting window in the eligible client set after startup. A positive result does not establish its UA-selection-time origin lookup, a repair, or qualification of another WebKit version. A missing host is unavailable, including versions that deliberately hide the hosting page.

## Current source/offline evidence

- Protocol RED (missing implementation), API-absence RED, post-spawn ownership-write RED and combined primary/retirement-failure RED are preserved under `mv3-renewed-boundary-2026-10-29` in the shared artifacts root.
-23 offline protocol/ownership controls pass; worker JavaScript syntax passes. DEBUG build6 passes after the independent absolute-deadline correction. Earlier failed builds remain preserved.
- Independent review found two P2s: late readiness/reply success after deadline, and post-Popen bookkeeping outside protected retirement. Current source checks absolute deadlines and protects launch bookkeeping/capture/write failure through the owned-launch finally scope; no advertised bound was extended.
- `capability-prepare-1` signed and verified an ad-hoc sandbox/Hardened Runtime normal app without launching it. Its preparation predates the deadline correction and is retained as earlier evidence, not current native qualification. Current signed preparation will have its own fresh provenance.
- No local native/UI app, test, remote run, push or PR has been started for this capability. No SDK capability result or UA fix is claimed.23 offline controls establish report/ownership behavior only.
