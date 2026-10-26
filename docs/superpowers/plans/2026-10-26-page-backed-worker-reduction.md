# Page-backed worker reduction

Purpose: remove Vane and WKWebExtensionController while retaining WebKit's page-backed worker loader, configured view identity, fresh persistent store and Safari→custom→Safari ordering. Observe the worker-script request header, captured worker startup/current UA, and the later worker report request header.

This is an explicitly SPI-assisted diagnostic, not the public-only probe or a product workaround. The script-request header is the live client's fetch identity; it does not reveal the Network-process origin-UA map. The later importScripts request reports a previously captured worker value and is auxiliary evidence. A passing finite cohort is inconclusive; a failure narrows the required components without proving an exact internal cause.

- [x] Add a standalone sandboxed hardened app with three contexts, fixed own synthetic script, nonce/URL/store/launch checks, exact original UA comparison and first-failure stop.
- [x] Use the existing owned-process runner for signing, primary and fresh post-exit cleanup, with a generated store UUID and preserved logs/identities. No ordinary Vane tests.
- [x] Add pure protocol/retirement guards, validate one local cohort and verify task-owned process exit/store retirement.
- [ ] Obtain independent review, push with skip-ci and dispatch only this reduction on disposable macOS26/Safari27.
- [ ] Preserve and audit the first result. Keep all upstream reports local per the user's instruction.

Local evidence: the initial eight-app cohort completed all 24 UA comparisons and retired its stores. Review found that native cleanup emitted numeric `1`; strict JSON boolean rejection and explicit native `@YES`/`@NO` fixed the reporting defect. A subsequent single-app integration passed all three stages and the strict cleanup protocol (`retired: true`). Its four tracked signing/verification/app/helper processes exited. Pure guards also reject incomplete stages, mismatched identities, numeric cleanup success and cleanup failure. CI bounds allow the complete eight-app phase envelope, including post-exit cleanup.
