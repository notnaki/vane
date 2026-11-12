# Security boundary repairs

**Goal:** Verify the October security report against current code and repair confirmed boundary failures without exposing private report details in public discussion.

**Approach:** Keep existing features and profile isolation. Restrict privileged web bridges to isolated worlds and trusted user interactions, authenticate bulk credential export, bind fills to the displayed document origin, and preserve source context when opening links. Review extension identity/permissions, HTTP authentication, file navigation, OAuth and HTTPS-only continuation independently.

**Constraints:** macOS 26+, existing Swift/WebKit APIs and test harnesses; no release or version changes. Only test-owned profiles, stores and app processes. Public issue acknowledgment contains no technical vulnerability details.

- [x] Verify each reported claim and distinguish source-confirmed paths from runtime-proven behavior.
- [x] Preview boundaries: reproduce page-world invocation and synthetic input; isolate the bridge and require trusted interaction and native source visibility.
- [x] Credentials: reproduce missing export authentication and outgoing-document fill; authenticate export, check expected origin in the isolated world, and reject provisional manual fills.
- [x] Extensions/OAuth: test permission default, signer disclosure, callback navigation admission and PKCE; repair verified failures.
- [x] Navigation: test cross-origin authentication challenges, web-to-file link routes, source-profile propagation, and HTTPS-only continuation provenance.
- [x] Audit hardening suggestions and make narrowly scoped repairs where behavior and coverage are clear; record limitations.
- [ ] Run focused regressions, pure checks and appropriate broader validation; obtain independent review and address findings.
- [ ] Push a reviewable PR, wait for required current-base CI and review, squash-merge, verify preservation and clean up task resources.

**Review focus:** synthetic versus trusted events; navigation replacement while work is pending; cross-profile/private boundaries; cancellation of owner authentication; callback redirects and source documents; preservation of ordinary browsing and extension installs.

## Evidence and scope

The primary findings have supporting source paths. Regression tests exercise rejected boundary crossings and successful legitimate operations; they do not constitute end-to-end attacks against real accounts. Real Developer ID, development, and Mac App Store signatures were checked locally. OAuth request construction is covered with the RFC 7636 vector and local fixtures; an interactive service-account login was not performed.

Additional repairs cover clipboard device scoping and owned-content cleanup, profile credential metadata, synthetic submit events, status/audio bridge isolation, extension private-data admission, and native certificate exception cookies that are freshly evaluated on reuse. Existing boolean certificate approvals require renewed consent. The page-world MediaSession adapter remains necessary to observe page-owned handlers; its metadata remains untrusted and bounded.

Download quarantine behavior needs a signed runtime provenance fixture before declaring a bypass. No remotely reachable icon-decoder exploit was established. Snapshot hashing requires a defined local-tampering model, and entitlement changes need signed WebRTC and legacy-migration checks. These recommendations are separate from the repaired primary findings.

Independent source and fixture reviews approved the changes. A review-found password-save regression was reproduced and repaired by separating committed submission authority from settled-document fill authority. Native fixture failures were retained and repaired through exact presentation admission, body-scoped AppKit ownership, and verified sheet/window retirement. The original outcome assertions and deadlines remain in place.

## Validation evidence

The full local native run on macOS 27.0.1 / Xcode 27 completed 2,938 tests (38 skips), with 33 failed cases and verified cleanup of 399 owned stores. Four failing extension/presentation admission cases were repaired and passed the focused preflight without weakening outcomes or deadlines. Twenty-nine other native UI cases remain unresolved locally; six sampled Space rendering/landing cases reproduce on unchanged base `5f6a2923a718f29453287ec06159b1e5da029784`. That comparison does not establish every remaining failure as preexisting. The exact remaining cases and original logs are retained in the task's local validation report; the user explicitly directed the security task to leave these UI cases to a separate agent. This accepts only that local scope limitation; the security task remains responsible for every CI failure on its PR and cannot merge until all required CI passes. Full required macOS 26 CI remains mandatory.

A subsequent 400-case security and integration preflight completed with two opt-in skips and exposed one inherited native activation-policy fixture error, now repaired by explicit lease policy with restoration after joined cleanup. Independent review then identified provisional certificate cancellation retaining a false untrusted state; new regression cases reproduced both Cancel and Stop failures before the repair. The final frozen security/integration preflight completed 405 tests with two opt-in skips and zero failures; cleanup verified 157 exact owned backends absent. An additional 85-case trust/navigation preflight and pure selfcheck passed, and independent final trust/fixture review found no actionable issues. Latest target integration and required CI are pending.
