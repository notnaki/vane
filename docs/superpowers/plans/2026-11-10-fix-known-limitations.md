# Fix actionable browser limitations

Scope: improve limits that Vane can address locally, excluding sync and passkeys. Keep system-WebKit crash guards and evidence boundaries for account, hardware, macOS and notarized-release checks.

1. Preserve Chromium, Firefox and Safari bookmark folder paths during native imports; preserve creation dates where the source provides them. Use Vane's existing flattened `Parent / Child` folder representation, existing duplicate policy and atomic history/bookmark transaction. Keep compatibility with older/minimal SQLite schemas.
2. Add optional password-protected exported backups using AES-256-GCM and PBKDF2-HMAC-SHA256 (600,000 iterations, random 16-byte salt). Authenticate the versioned header, keep file limits and atomic 0600 writes, avoid plaintext temporary export files, and continue reading old backups. Local recovery points keep their existing format. Default the export UI to encryption, confirm the password, and request it when opening an encrypted backup before preview or restore.
3. Expand safe EasyList conversion for case-sensitive URL matching and negated resource types only when WebKit can represent them without conflating unrelated types. Keep unsupported options rejected and reported.
4. Add behavioral regressions first, run focused tests and required CI, obtain independent review of the final diff, fix findings, open a PR and squash-merge once integration checks and current main are green. Preserve all unrelated work and clean up task-owned worktree/apps after merge.

Validation: focused backup/controller, browser-data fidelity/import worker, blocker conversion and actual WebKit rule tests; full required CI covers integration. Record remaining limitations truthfully in the user docs.

Validation on macOS 27.0.1 / Xcode 27:

- Baseline: 53 focused tests passed.
- New regressions reproduced missing encryption, discarded native bookmark metadata, rejected filter options and the review-discovered Firefox duplicate-order error before their fixes.
- Backup/import/blocker focused wrapper: 159 tests passed with verified fixture cleanup.
- Final importer/Arc integration wrapper after the ordering fix: 68 tests, one existing opt-in Arc Keychain skip, zero failures; cleanup passed.
- Independent Python plistlib/hashlib/cryptography fixture decrypted successfully, covering the fixed KDF/format contract.
- Pure selfcheck, 10 native-shard routing fixtures and diff checks passed.
- Independent review found the Firefox source-order issue; replaced global bookmark ordering with ordered depth-first traversal and added its failing-then-passing duplicate regression. No further initial review findings.
- Actual native password-dialog interaction is not claimed by these controller tests. No app activation, ordered-front windows, input injection or screen capture was used; foreground coordination with other tasks was preserved.
