# Project workflow

## UI animation defaults

- Animate interactions and state changes by default unless the user opts out. Keep motion brief, responsive, and consistent with Vane's styles. Animate shape/orientation changes continuously (e.g. rotate the creation menu's + into × and back).
- Respect system Reduce Motion and Vane's Battery Saver motion policy; change state immediately when motion is reduced.

## PR, review, and squash-merge cycle

- Unless the user specifies another stopping point, implement, validate, open/update a PR, review, fix findings, and squash-merge. Use a `codex/` branch, never commit directly to `main`; preserve unrelated local work and include only task changes.
- Choose focused local builds/tests/checks from `README.md` for the affected behavior. Trivial changes need no full suite; docs generally need only a diff check. Run the full local suite for broad/high-risk changes, unresolved failures, or explicit requests. Required CI still applies.
- After validation, push and open/update the PR with a clear description and results. Obtain independent review of its current diff through a PR reviewer or review subagent; fix actionable findings, push, and repeat review and relevant validation until none remain.
- Run full required CI directly unless investigating a CI failure (including runner-dependent failures). Then use a focused preflight covering affected cases and related fixtures, preserving assertions, outcome deadlines, and cleanup checks. Predetermine intermittent-case repetitions and retain every attempt. Proceed to full CI only after the preflight passes and earlier failures are explained and repaired.
- A passing retry on unchanged code does not resolve a native assertion failure: preserve the original evidence, investigate, reproduce, repair, and validate. Evidenced runner outages before tests execute may be retried and must be reported separately. Only explicitly accepted, narrowly named limitations may be advisory; passing advisory samples do not prove a fix.
- Before native regression actions, admit the required AppKit loop, foreground/document state, and exact visible presentation owner. Use bounded observable prerequisites instead of guessed readiness sleeps. Preserve outcome assertions/deadlines; never await the desired outcome before an early-animation sample.
- Merge only when the latest PR commit is reviewed, required CI passes on its integration with the latest target branch, required approvals are satisfied, and the PR is mergeable. If the target advances, update the PR and validate the combined tree. Keep `main`'s strict required `checks` protection and administrator enforcement enabled. Report pending/unavailable reviews or checks as blockers; never bypass them.
- Immediately before merging, recheck `main`'s HEAD and CI status and all merge requirements above. Wait for every unfinished `main` CI run; never cancel one to unblock a merge or let a merge cancel/supersede it.
- Squash-merge into the target branch without further confirmation unless later user instructions or repository policy require it. Verify the merge; report the PR link, squash commit, and validation results. Sync the local target only if existing local work is preserved.

## Test app cleanup

- Track bundle path, PID, and start time for every task-launched Vane test copy, including worktree/temp builds. After merging, quit all before reporting completion; also clean up when abandoning the task.
- Target only tracked instances; leave the user's regular app and other tasks' instances running. Never use blanket `killall Vane`/`pkill vane` commands.
- For "Quit Vane?", verify the dialog belongs to the tracked instance and choose "Quit" (or Return in its focused dialog). Never choose "Quit and don't ask again" or change that preference. A quit request alone is insufficient.
- If confirmation blocks quitting or the process remains, the authorized fallback is `kill -TERM <pid>`, then a brief wait/exit check and `kill -KILL <pid>` only as a last resort. Revalidate the PID's executable and launch before each signal to guard against PID reuse.
- Verify exit of every tracked process. Report any remaining instance and blocker; do not claim successful cleanup.

## Worktree cleanup

- After merging or abandoning a task, remove its worktrees once work is preserved and task-owned test apps have verifiably exited. Include documentation/change worktrees.
- Before removal, inspect `git worktree list --porcelain`, tracked/untracked changes, ignored files, branch/HEAD, related PR status, and processes using the checkout. Age alone proves nothing.
- Preserve the primary checkout, active/open-PR worktrees, and uncommitted/unpreserved work. Remove other tasks' worktrees only on explicit request. Retain uncertain candidates and report why.
- Verify committed work is preserved in the target branch or a merged PR. For squash merges, check local HEAD is included in the PR's final head and preserve its branch or another recovery ref; target ancestry alone is insufficient.
- Use Codex's archive-worktree tool for managed worktrees attached to this chat (recoverable snapshot); separately preserve needed ignored files, which it excludes. Otherwise use `git worktree remove <path>` without force. Discard ignored build products only if confirmed disposable; preserve user data and needed files.
- Never blanket-delete directories, force removal, or delete branches with unpreserved work. Prune stale metadata only after verifying its checkout no longer exists.
- Verify removed paths are gone and absent from `git worktree list`; report removals and retained worktrees.
