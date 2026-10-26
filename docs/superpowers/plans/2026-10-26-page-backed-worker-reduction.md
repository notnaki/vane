# Page-backed worker reduction

Purpose: remove Vane and WKWebExtensionController while retaining WebKit's page-backed worker loader, configured view identity, fresh persistent store and Safari→custom→Safari ordering. Observe the worker-script request header, captured worker startup/current UA, and the later worker report request header.

This is an explicitly SPI-assisted diagnostic, not the public-only probe or a product workaround. The script-request header is the live client's fetch identity; it does not reveal the Network-process origin-UA map. The later importScripts request reports a previously captured worker value and is auxiliary evidence. A passing finite cohort is inconclusive; a failure narrows the required components without proving an exact internal cause.

- [x] Add a standalone sandboxed hardened app with three contexts, fixed own synthetic script, nonce/URL/store/launch checks, exact original UA comparison and first-failure stop.
- [x] Use the existing owned-process runner for signing, primary and fresh post-exit cleanup, with a generated store UUID and preserved logs/identities. No ordinary Vane tests.
- [x] Add pure protocol/retirement guards, validate one local cohort and verify task-owned process exit/store retirement.
- [x] Obtain independent review, push with skip-ci and dispatch only this reduction on disposable macOS26/Safari27.
- [x] Preserve and audit the first result. Keep all upstream reports local per the user's instruction.

Local evidence: the initial eight-app cohort completed all 24 UA comparisons and retired its stores. Review found that native cleanup emitted numeric `1`; strict JSON boolean rejection and explicit native `@YES`/`@NO` fixed the reporting defect. A subsequent single-app integration passed all three stages and the strict cleanup protocol (`retired: true`). Its four tracked signing/verification/app/helper processes exited. Pure guards also reject incomplete stages, mismatched identities, numeric cleanup success and cleanup failure. CI bounds allow the complete eight-app phase envelope, including post-exit cleanup.

Hosted result: [run40359442371](https://github.com/notnaki/vane/actions/runs/40359442371) at `511c6c9aaa176b5107f815dba31cdb1204235709` passed eight apps / 24 distinct context nonces and comparisons. Every script/report header matched, all primary/helper exits were verified, and all eight exact stores retired. Independent artifact audit agreed. Original Vane arms were skipped. Safari27 installation and staged linker configuration were verified; this reduction did not capture loaded worker images. The finite pass does not repair the extension failure or prove controller involvement is necessary.

Next focused observation: only after the original signed MV3 UA comparison fails, read the bound registering document's live `navigator.userAgent`, URL, origin and ready state. Use a fresh read nonce, revalidate the current context/view on callback and bound the read to one second. Do not inject scripts, read before comparison, change the UA verdict, retry, or continue to a later trial. This can distinguish native proxy identity from the live registering page; it cannot recover that page's startup UA or inspect SWServer's origin-UA map. Build and review this diagnostic before running only the failing unregistered arm.
