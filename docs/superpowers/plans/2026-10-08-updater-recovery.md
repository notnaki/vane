# Updater failure recovery audit

Start: origin/main dee7b89, isolated codex/updater-failure-recovery worktree. Host: macOS 27.0.1 (26A434). Keep all fixtures under task-owned temporary directories; never install into real Applications directories.

## Inspection completed

Read Updater.swift (URLSession download, ditto extraction, pinned team validation, XPC installation, restart helper), UpdateInstaller.swift and InstallerService.swift (mutual Developer ID requirements), UpdateInstallation.swift (destination policy, final-copy signature validation, Gatekeeper, quarantine removal), BundleReplacement.swift (flock, full sync, prepared/launching/healthy journal, RENAME_SWAP, rollback and cleanup), main.swift (startup and health criteria), README validation commands and installer fixtures.

## Execution

1. Compile a standalone helper against production updater transaction sources. Run existing inline transaction checks and signed installer checks as baseline. Use a published unchanged release ZIP for real distribution validation. Record codesign, stapler and spctl results separately from synthetic policies.
2. Add reproducible failures before fixes: unrelated Vane.app destination with lower version; edited/incomplete old and new directories with unchanged inode; forged/stale or symlink transaction records; process death before copy, after copy, before sync/journal/swap, after swap and during launch/rollback/health/cleanup. Assert old contents remain recoverable and no false health or unrelated mutation occurs.
3. Harden only confirmed defects. Preserve staging, same-user XPC, durable journal and atomic swap. Bind recovery to validated bundle identity and transaction contents; reject unusable/unsupported payloads before replacement. Retain filesystem and verification errors. Exercise repeated failures and retries.
4. Exercise downloads with controlled loopback HTTP: abort, false content lengths, oversized responses; ditto with corrupt/truncated ZIP and unwritable extraction roots. Production trust-host decisions stay pinned; loopback is fixture transport only.
5. Request coordinated build and native-launch slot from smoothness chat. Build disposable app, launch with isolated data, record executable/PID/start time, test crash-before-health and health completion. Test restart-tool failure through injected process runner where practical. Never change installed Vane or its profile/preferences.
6. Run focused installer/transaction regressions, pure selfcheck and Swift tests appropriate to risk. Add headless fault suite to CI. Document exact evidence, simulated checks and any unavailable distribution/UI prerequisite.
7. Commit only task changes, create PR, obtain independent current-diff review, fix findings and revalidate. Require latest commit review, passing required CI and mergeability before squash merge. Verify merge commit. Revalidate and stop all task-owned processes, delete disposable bundles, retain text evidence.

## Review focus

Journal identity is not authority; same inode is not proof of intact content. Never erase the only usable old bundle before durable health. Recovery errors must not produce health. Concurrent launching processes cannot roll back a live launch. Cleanup interruptions must be idempotent; failed retries must preserve recovery. Real Gatekeeper/signature results must be reported separately from injected predicates.
