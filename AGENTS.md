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
