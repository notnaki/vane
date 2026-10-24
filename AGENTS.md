# Project workflow

## UI animation defaults

- Animate UI interactions and state changes by default unless the user explicitly requests otherwise. Keep motion brief, responsive, and consistent with Vane's existing motion styles.
- When a control changes shape or orientation, animate the transition continuously instead of swapping between static icons. For example, the creation menu's + should rotate into × when opened and rotate back when closed.
- Respect system Reduce Motion and Vane's Battery Saver motion policy; use immediate state changes when motion is reduced.

## PR, review, and squash-merge cycle

- For requested project changes, carry the work through implementation, validation, a pull request, review, fixes, and squash-merge by default, unless the user explicitly requests a different stopping point.
- Work on a `codex/` branch rather than committing directly to `main`. Preserve unrelated local changes and include only the task's changes in commits and the PR.
- Use focused local validation for most changes: select only the relevant build, tests, or checks documented in `README.md` based on the affected behavior. Trivial changes do not need the full local test suite; documentation-only changes generally need only a diff check. Run the full local suite when broad changes, higher-risk behavior, or unresolved failures justify it, or when explicitly requested. Required CI checks still apply before merging.
- After relevant validation, push the branch and open or update the PR with a clear description and validation results.
- Obtain an independent review of the PR's current diff through the available PR reviewer or a review subagent. Address actionable findings, push fixes, and repeat review and relevant validation until there are no unresolved actionable findings.
- Before merging, confirm the latest PR commit has been reviewed, all required CI checks have passed, required approvals are satisfied, and the PR is mergeable. A pending or unavailable review/check is not a pass; report the blocker instead of bypassing it.
- Squash-merge the PR into its target branch once those conditions are met. This is the user's standing project preference; do not ask for an additional merge confirmation unless a later user instruction or repository policy requires it.
- Verify the PR was merged and report its link, the squash commit, and validation results. Sync the local target branch only when doing so preserves existing local work.

## Test app cleanup

- Track the bundle paths, process IDs, and process start times of any Vane test copies launched for the task, including copies in worktrees or temporary build directories.
- After a successful merge, quit every Vane test instance launched for the task before reporting completion. Also clean up these instances when abandoning the task.
- Target only the tracked test instances; leave the user's regular Vane app and instances belonging to other tasks running. Do not use blanket commands such as `killall Vane` or `pkill vane`.
- A normal quit can stop at Vane's "Quit Vane?" confirmation. When using UI automation, confirm the prompt belongs to the tracked test instance and choose "Quit" (or press Return in that instance's focused dialog). Do not choose "Quit and don't ask again" or change the user's quit-confirmation preference. Sending a quit request alone does not count as cleanup.
- If the confirmation cannot be handled or the owned test instance remains running, terminate that specific process with `kill -TERM <pid>`. Wait briefly and check for exit; if it still remains, use `kill -KILL <pid>` as a last resort. Before each signal, revalidate that the PID still belongs to the tracked test executable and launch, since PIDs can be reused. This fallback is authorized for task-owned test instances; do not leave them running merely because a quit confirmation is blocking normal exit.
- Verify the tracked test processes have exited. If cleanup is blocked, report the remaining instance and reason instead of claiming cleanup succeeded.

## Worktree cleanup

- After a successful merge or when abandoning a task, clean up worktrees created for that task once their work is preserved. Quit and verify exit of task-owned test apps first, following the test app cleanup rules above.
- Before removal, inspect `git worktree list --porcelain`, the checkout's tracked and untracked changes, ignored files, branch/HEAD, related PR status, and processes using the checkout. Age alone does not establish that a worktree is safe to remove.
- Preserve the primary checkout, active worktrees, open-PR worktrees, and checkouts with uncommitted or unpreserved work. Do not remove another task's worktree unless cleanup of it is explicitly requested. Leave uncertain candidates in place and report why.
- Confirm committed work is preserved in the target branch or a verified merged PR. Squash merges may leave the source commits outside the target branch's ancestry; check that the local HEAD is included in the merged PR's final head and preserve its branch or another recovery ref.
- Use the Codex archive-worktree tool for managed worktrees attached to the current chat; it saves a recoverable snapshot. Preserve any needed ignored files separately because the snapshot excludes them. For other worktrees eligible for cleanup, use `git worktree remove <path>` without force. Discard ignored build products only after confirming they are disposable; preserve user data and other needed files.
- Never use blanket directory deletion, force removal, or delete branches with unpreserved work. Prune stale Git worktree metadata only after verifying the corresponding checkout no longer exists.
- Verify removed paths are gone and `git worktree list` no longer includes them. Report what was removed and what was retained, and clean up the documentation/change worktree too once its PR has merged.
