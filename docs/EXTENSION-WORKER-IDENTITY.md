# Extension worker identity boundary

Vane uses system WebKit for Manifest V3 extension workers. The SDK can construct a worker whose initial and current `navigator.userAgent` is the bare WebKit UA while the extension popup and native configuration use the selected browser-page identity. Applying the page UA again is not an acknowledged worker-construction barrier.

This is an accepted platform limitation, recorded with the original failures in [#513](https://github.com/notnaki/vane/issues/513), rather than a claimed repair. That issue can close as **not planned** under the requested no-fork constraint. There is no engine fork, bundled replacement, script rewriting, navigator override, manifest conversion, process-sharing relaxation, or disabled MV3 support. The worker runtime and extension permissions/storage remain unchanged.

An extension that infers its browser solely from worker UA can still be affected. Closing the investigation does not establish universal compatibility. The separate Bitwarden Safari 2026.10.0 popup issue concerns an MV2 background page and is assessed independently using the actual unmodified package.

## CI boundary

The existing single `testKnownServiceWorkerUserAgentLimitation` probe keeps all desired startup/current assertions. Only the exact nonnil bare-engine UA mismatch is advisory. Its manifest, discovered selection, one completed execution, nonce/context/runtime/origin checks, cleanup, and evidence archive remain required. Unknown assertions, missing execution, crashes, timeouts, startup/API failures, permission/storage/ownership failures, and cleanup failures still block required checks. A passing sample is not a fix.

The four normal native shards still run every other discovered test. Popup UA, MV2 background UA, real extension startup, SDK behavior, profile boundaries and native regression failures remain blocking. Main retains strict latest-main `checks` protection including administrators.

## Closeout

The useful production repairs from the investigation are consolidated in PR #560: compact SDK-owned windows, separately reviewed native-messaging error compatibility, runtime diagnostic classification, and qualified native-test readiness/callback/mounting controls. Diagnostic PRs #503 and #520 and the unproven configuration candidate #519 are archived unmerged, preserving their branches and evidence. Closing those PRs does not merge their experimental workflows or engine probes.

On 2026-10-31 the user explicitly authorized running full required CI for PR #560 despite the unexplained historical `b029274` password-document failure, with that test still mandatory and blocking. This is a narrow exception to the earlier full-CI hold, not a claim that the historical failure is fixed. Any new native failure must be preserved and investigated; a passing unchanged retry does not repair it. Merge still requires independent current-diff review, latest-target integration and all required checks.

## Consolidated qualification

The combined affected-case preflight selected 359 exact cases: 358 passed, one existing live-store opt-in case skipped, zero failed. The historical password case remained selected and passed in this sample; its historical cause remains unresolved. Canonical inventory verification confirmed every selected case completed. Primary/cleanup statuses were zero, 212 exact backend stores retired, both owned hosts exited, and source/binary fingerprints remained frozen. This includes the local signed Safari-installation coverage. The native build passed; strict classifier and shard fixtures passed; the workflow matrix preserved all 8,227 failure/coverage gate combinations. Independent review found no actionable findings in the full consolidated product and test diff.

Full required CI and actual-main verification remain the production-delivery gates. The preflight is not a claim of universally deterministic WebKit behavior or a repair of the recorded worker identity.
