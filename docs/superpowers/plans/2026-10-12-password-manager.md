# Password manager implementation plan

Goal: Make the existing Keychain password manager dependable for everyday use without changing existing credential identities or adding passkeys.

Architecture: Keep Passwords as the Keychain owner and Autofill in its isolated WebKit world. Extend conservative field classification, native review/generation UI, and checked Keychain operations. Keep profile and test namespaces unchanged.

Constraints: No secret diagnostics, backend, cryptography, automatic submission, plaintext-export additions, private-mode credential access, or passkey substitute. Preserve legacy default HTTPS identities and existing import/export.

1. Form classification and submission fixtures: add regressions for ambiguous passwords, semantic unrelated fields, replaced username targets, confirmation mismatch, and abandonment. Run them red. Implement conservative detection, document/field identity, focused embedded-frame guards, and credible submission capture; run password fixtures green.
2. Generator: test selected character groups and bounds; add configurable options and isolated-world new-password targeting with revalidation between event handlers. Integrate a native field-anchored generator in signup/change fields, with keyboard and accessibility support.
3. Keychain operations and manager: retain compatibility wrappers; surface sanitized OSStatus failures for enumerate/read/write/delete; add safe identity edits, refresh and sorting; test failure injection and isolated persistent-reference preservation. Preserve authentication, automatically hide drafts/reveals, and test clipboard ownership.
4. Save review: test duplicate attempts, new-versus-existing account classification, rejected login copy, and collision refusal. Add editable website/account/password review with explicit update confirmation; remove default Return interception. Keep Never Save reversible and profile-local.
5. Validate and document: run focused password tests, pure checks and signed app fixtures with disposable storage; inspect rendered UI. Record fixture versus real-site and signing limitations. Independently review current PR head, fix actionable findings, satisfy CI, squash-merge, verify merge and owned-process cleanup.

Review focus: navigation during async work; DOM event handlers replacing fields mid-fill; renamed credentials colliding with other accounts; Keychain failures mistaken for absence; popup keyboard actions stealing page input.

Execution: inline implementation and one independent review, followed by any required re-review. The user's explicit end-to-end instruction supplies implementation and merge authorization.

Implementation ledger:
- Implemented all five tasks inline. Existing storage namespaces and default HTTPS IDs remain unchanged; identity edits use SecItemUpdate rather than replacement.
- Reproduced unsafe ambiguous fills, stale username targeting, mismatched confirmations, offscreen fields, cross-origin form actions, ambiguous generation and autocomplete-off automatic fills before fixing them.
- Focused validation: 83 password-related tests passed with VANE_TEST_KEYCHAIN=1, including native popup snapshots and Keychain import/export. Full suite before the final focused refinements: 1,096 tests, 14 skips, zero failures.
- Ad-hoc signed sandbox smoke: 200 WebKit assertions; fresh-process Keychain persistence/profile/port isolation and deletion passed. Native signed UI add/generate/save/detail/reveal/hide/delete flow exercised with a disposable .invalid account.
- Remaining: latest-head independent PR review, required CI, squash merge, owned-process exit verification. Real provider sign-ins, notarized upgrades and complete device/VoiceOver validation remain separate.
- Independent review of c6c0b247 found one P2: iframe focus needed revalidation after site input handlers, including between generated confirmation writes. Both cases reproduced red in real-WebKit tests. A shared focus-chain guard now runs before every secret write; all 85 focused password tests passed after the fix. Latest-head re-review requested before merge.
- Task-owned manual UI process and sandbox cleanup process exited; the disposable credential and website store were removed. Signed selfcheck removed that instance’s isolated preferences.
