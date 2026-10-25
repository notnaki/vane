# WebKit Comparator Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the two independently owned implementation tasks, then independent review of the combined diff.

**Goal:** Determine whether the remaining #484 failures reproduce with an official newer WebKit that contains the upstream custom-scheme origin correction.

**Architecture:** Keep the ordinary system-engine job unchanged. Add an isolated, ephemeral CI job using a pinned official WebKit archive and require proof that XCTest and its WebKit services actually use that archive. This diagnostic does not ship an alternate engine or establish a production repair.

**Tech Stack:** GitHub Actions, Python, Swift XCTest, WebKit.

**Spec:** The requirements and acceptance gates below define this bounded diagnostic.

## Global Constraints

- Archive: Tahoe universal Release `324648@main`, source `070ff828ed26b6305dd78575369cdddb79b5411f`; size 332339110; single-part ETag/MD5 `6d17a7645877eb9e24f04299efc7deb4`.
- Preserve original assertions, deadlines, failure status and manifest-owned cleanup. Stop reproduction at its first failure.
- No product entitlement changes, OS security changes, local binary download or local native work during the peer's exclusive build reservation.
- `VANE_WEBKIT_COMPARATOR_PRODUCTS` names the canonical extracted Release directory; `VANE_WEBKIT_COMPARATOR_VERSION` names its framework plist version; `VANE_WEBKIT_UA_REQUIRE_CLIENT=1` enables the behavioral anchor only in the comparator.
- Keep #484 open and #503 draft until an actual repair satisfies independent review, ordinary CI, merge and main verification.

## Review Focus

- System framework or XPC fallback must fail provenance checks, even when tests pass.
- Unsupported architecture, OS deployment target or loading must report comparator unavailable.
- Truncated downloads, wrong archive contents and archive integrity mismatch must fail before execution.
- Zero selected tests, missing case markers, fatal errors and cleanup failure must fail the job.
- Late client enumeration must be bounded and remain associated with the current generation/runtime; ordinary system tests must stay unchanged.

### Task 1: CI archive launcher

**Files:** `.github/workflows/checks.yml`, `scripts/run-webkit-comparator.py`.

- [x] Add a separate macOS 26 job that builds normally, verifies/extracts the exact official archive and inspects its executable compatibility.
- [x] Launch the existing native wrapper with the official DYLD/XPC environment, resolving the toolchain Swift path before setting it.
- [x] Run the framework probe, then the five UA cases that await script identities and two password cases in bounded fresh hosts. Require exact pass markers, wrapper success and cleanup; stop at first failure.
- [x] Verify syntax and guard failure paths without downloading or executing WebKit locally.

### Task 2: Runtime provenance and behavioral anchor

**Files:** `Tests/VaneTests/ExtensionUserAgentPolicyProbeTests.swift`, `Tests/VaneTests/WebKitComparatorAttestation.swift`, `Tests/VaneTests/ExtensionUserAgentTests.swift`, `Tests/VaneTests/PasswordAutofillTests.swift`.

- [x] In comparator mode, require the loaded framework's canonical path and public version to match the archive.
- [x] Require existing owned WebContent and Networking service executable paths to match the archive in the probe and each actual original fixture while live; unavailable proof fails acceptance. Bind exact marker counts to each XCTest case. The teardown-only UA case remains in ordinary CI and is excluded from this comparator because it does not await script identities.
- [x] After the existing worker identity assertions, require bounded current-popup client enumeration in comparator mode only.
- [x] Review Swift availability, ownership/privacy boundaries and unchanged ordinary-system behavior at `71f7ea3`; both jobs completed in CI.

### Task 3: Combined review and evidence

- [x] Independently review and publish `71f7ea3`, update #484 and collect both jobs in run40227653569.
- [x] Record the system failure and the attested comparator passes with cleanup. The archive ran on arm64 macOS26.6.2 and declares minimum macOS26.5/SDK26.5; it cannot replace Vane's engine across26.0–26.4. Vane's minimum remains26.0. The comparison does not isolate one WebKit commit as the cause.

### Task 4: Native host and owned-window presentation comparison

PR505 merged as `c40c2f4` after exact review and green ordinary PR CI (1,897 tests,140 skipped,0 failures). Its actual-main run40233105701 failed before navigation: Password EmbeddedSelection reached active/key/on-screen/finished-launch state but occlusion8192 lacked the visible bit2. The later strict contract, Replacement, UA6, Reader18 and toast6 passed; all203 owned backends retired, wrapper1/0. This is not a verified repair or a reason to rerun an unchanged commit.

- [x] Review a one-shot owned-window layout/display request after queued activation/key events during setup; keep the strict visibility predicate, five-second deadline and original assertions. Add only finite failure metadata for active Space, minimization, dirty layout/display and positive alpha. Source review does not establish effectiveness.
- [x] Review and run a finite original-UA fixture contract: finished launch at entry and after100ms idle. The fresh local host failed both assertions as expected (one test, two expected failures, zero unexpected,1.227s). Activation/key/visible windows are diagnostic only; background workers must remain valid without them. Original setup merely instantiates NSApplication.shared. This proves a local fixture gap, not UA causation; a later-sorting contract cannot certify earlier controller creation. Cleanup verified one backend absent and all36 tracked compiler/test PID/start identities exited.
- [x] Review DEBUG-only `extensioncheck --user-agent-only` using the existing normal NSApp.run driver, fresh signed sandboxed isolated data and four synthetic production-host identity stages. Require completed launch and appRunning before profile/controller creation; no manual finish/activation/event drain. Preserve startup/current-UA, nonce/runtime/origin/version and actual callback pool/store/identity checks.
- [x] Independently review and validate the bounded runner and15 pure guards. Require five unique positive findings, a valid report, process exit and positive post-exit isolated-store cleanup. Preserve the first failure and stop; do not claim unrecorded backend PID provenance. AST/YAML/diff checks and the local native-test build passed.
- [x] Run `31e79718` on actual macOS26 in CI40235821371. The full system suite passed1,911 tests/140 skips/zero failures, including Password47, and both eight-trial original/password cohorts passed. The fresh launch contract failed its two launch assertions; the fresh framework control reproduced two bare-worker-UA assertions after custom identity. The signed normal-loop runner passed all eight trials with five required positives and post-exit cleanup; all24 signing/app/cleanup process exits were verified. All native cleanup passed. Successful app report contents were validated but deleted without printing exact OS/WebKit metadata, so do not quote unseen values. The separate newer-engine comparator also passed its attested eight cohorts. The system job remains failed because fresh diagnostic failures are preserved; this does not establish main or Bitwarden compatibility.
- [ ] Use the results to distinguish fixture readiness from production behavior. A green XCTest contract or isolated probe does not prove Bitwarden compatibility or repair the system worker-UA boundary. Keep #484 open and #503 draft.

### Task 5: Admit the actual extension test host before controller creation

- [x] Independently review a shared test helper that requests guarded launch once and dispatches at most32 already queued AppKit-defined events per setup pass. Its five-second admission checks the real NSRunningApplication.isFinishedLaunching and changes no activation policy, windows, JavaScript or identity. Completion under prohibited policy is not guaranteed by documentation; fail closed if it cannot occur.
- [x] Admit original UA setup after teardown-safe profile/folder initialization and the framework probe before datastore/controller creation. Preserve all assertions and deadlines. Guard teardown against creating a host when admission failed or was cancelled; preferences, folders and owned-profile release still run. PW only shares its existing launch/event helpers and retains the reviewed foreground/display predicate.
- [x] Independently review the runner's observation-only update: require a concrete numeric WebKit version and echo all five bounded JSON findings only after full validation, before successful artifact cleanup. All18 pure guard tests pass; default validation remains silent and process/cleanup behavior is unchanged.
- [ ] Build and run this source candidate on actual macOS26. Local binaries still represent31's source and must not be used with --skip-build for this candidate. No native/runtime improvement is claimed before CI.
- [ ] If the focused repair is demonstrated, extract only the required fixture change into a separate reviewed PR, require its ordinary CI to pass, squash-merge and verify actual main. Do not merge this diagnostic branch as the repair.
