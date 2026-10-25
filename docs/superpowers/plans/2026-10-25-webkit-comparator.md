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
- [ ] Review Swift availability, ownership/privacy boundaries and unchanged ordinary-system behavior; native validation runs in CI if the peer reservation continues.

### Task 3: Combined review and evidence

- [ ] Obtain independent review of the current combined diff and address findings.
- [ ] Push the diagnostic draft, update #484 with the exact head and wait for both ordinary and comparator CI.
- [ ] Record provenance, first failures and verified cleanup. Use the result to select a justified repair or identify the external engine boundary; a green diagnostic alone is not a fix.
