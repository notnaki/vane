# Crash and session recovery implementation plan

**Goal:** Recover saved regular browsing state safely on macOS 27, with explicit page recovery and no automatic crash/reload loop.

**Scope:** Existing Session, Crash, Tab termination, and native page presentation. Synthetic data and disposable signed app copies only. Preserve private exclusions and unrelated work. Complete validation, independent review, CI, and squash merge.

1. Reproduce current failures with XCTest and signed disposable app fixtures: corrupt primary with valid previous snapshot; active/background process termination; app SIGKILL/SIGTERM; repeated restoration crashes; multiwindow/profile/Space/pin/split persistence.
2. Add recoverable session file reads/writes: atomic publication, validated previous copy, preserve damaged originals before replacement, fail closed when preservation or storage fails. Preserve launch originals before unclean recovery writes.
3. Pause pages restored after unclean shutdown and pages whose WebKit process terminates. Persist the pause through session and Space sidecar round trips. Explicit recovery uses a fresh URL request, without replaying opaque POST history.
4. Restore saved windows across regular profiles while preventing intermediate restore writes. Retain selected identities, duplicate URLs, pins and splits.
5. Run focused regressions, full XCTest and pure checks, signed synthetic browser checks and subprocess interruption checks. Record OS, commands, outcomes, limitations, and owned-process cleanup.
6. Push a codex branch, create and attach PR, obtain independent review of current head, fix findings and repeat validation. Merge only after required CI/approvals and mergeability pass; verify squash commit and cleanup.

**Review focus:** Preservation failures must block replacement; corrupt/future files must not decode as empty; private windows must never reach recovery files; split presentation must not implicitly wake paused pages; repeated startup failure must preserve the original snapshot.
