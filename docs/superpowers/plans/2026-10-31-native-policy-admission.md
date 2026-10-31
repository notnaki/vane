# Declared native fixture activation policy

Keep system WebKit unchanged. This repair affects native test admission only.

The current window fixture requests accessory policy before constructing its loop, then the loop snapshots another getter as its invariant. A declared target must be observed before fixture actions instead. Existing default-nil callers keep their immediate policy invariants. This does not establish the exact cause/value of the earlier uninstrumented startup-policy failure.

## Contract and sequence

1. Preserve ownership, existing-loop, delegate, modal, and launch-open checks before any policy mutation.
2. For an explicit target, claim ownership and arm the existing 12-second startup watchdog. Start one five-second policy/admission budget before the SDK request. Feed every observed pending state before/after the request and at entry into the same admission history.
3. Make one real AppKit policy request. Retain its Boolean as metadata; false alone neither authorizes a mismatching policy nor rejects an already-correct observed state. The diagnostic receipt proved false with actual requested policy already present, but did not establish why AppKit returned false.
4. Observe actual policy together with native launch/readiness prerequisites. Poll only getters; never repeat the setter to manufacture success. Reuse the original budgets through heartbeat and caller handoff, checking time after getters and synchronous fault hooks. Warm finished-at-entry handling requires compound readiness with no observed pending history.
5. After admission, policy drift remains an immediate failure. Closing retains the exact declared target and the existing bounded shutdown/join behavior.
6. Migrate all four acquisitions in ExtensionWindowTests to declared accessory policy and remove its earlier unchecked setup request. Keep teardown restoration.

## Evidence and remaining work

Two invalid controls failed their own prerequisites and remain preserved. A diagnostic receipt identified a redundant request returning false while its actual target was present. The corrected real-SDK control `activation-admission-red-state` established accessory 1, requested regular 0, observed recovery to 0, and failed only the expected old `policyChanged` assertion. Primary status 1, cleanup 0; both tracked hosts exited; source and binary hashes were frozen. No SDK getter is mocked.

Implement the contract, add real-SDK permanent mismatch, original-budget late entry, post-admission drift, default-policy strictness, and foreign-owner controls. Run one focused control/window cohort first. Preserve all results. Broader integration and full required CI remain blocked until failures are repaired and explained; a later pass alone does not erase an earlier failure.

## Qualification

The first 31-case focused attempt passed. Independent review required three changes: retain the default deadline before its native getter, restore policy when setup throws, and always join the foreign-owner control even when verification fails. The corrected 31-case attempt passed. A broader 173-case extension preflight passed 172 with one existing live-store opt-in skip; 13 signed Safari installation cases passed separately. The original signed-mode protocol overcounted because the mode file extends `ExtensionNativeMessagingErrorTests`: its 13 methods were already included in the 173. The original protocol/logs and an explicit selection correction remain preserved.

A final review removed an unused explicit-mode native launch getter so every compound observation belongs to the pending admission history. The final frozen combined cohort selected 186 cases: 185 passed, the same live-store opt-in case skipped, and zero failed/unexpected. All six real-SDK policy controls passed. Canonical primary and cleanup statuses were both zero, all recorded backend retirement completed, and both exact owned test hosts exited. Build and diff checks passed. Independent full composed-diff review against main `641bc399` found no unresolved actionable findings.

Evidence is retained under `mv3-copy-boundary-2026-10-31/activation-admission-{red-state,focused,reviewed,extension,signed-mode,final}` in the task artifact root. The final cohort deliberately excludes only the separately accepted known worker-UA limitation; it does not establish an MV3 worker-UA repair. No engine was forked, bundled, patched, or built. The uninstrumented earlier startup failure still has no exact raw-value/phase trace; this qualification establishes the declared-policy admission contract rather than an invented internal cause. Historical `b029274` navigation failure and latest-main full required CI remain separate unresolved merge gates. Neither #513 nor #484 is closed by this local qualification.

## Authorized closeout on 2026-10-31

The user explicitly authorized full required CI for the consolidated PR #560 while retaining every test as blocking. This supersedes the earlier full-CI hold described above only for that validation. The historical `b029274` password-document failure remains unexplained and is not reclassified as advisory or fixed. Its original test remains mandatory; any fresh failure stops advancement. The exact worker-UA discrepancy remains the sole narrowly accepted advisory platform limitation. Strict latest-main checks, independent review and administrator enforcement remain required.
