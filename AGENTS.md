# Project workflow

## PR, review, and squash-merge cycle

- For requested project changes, carry the work through implementation, validation, a pull request, review, fixes, and squash-merge by default, unless the user explicitly requests a different stopping point.
- Work on a `codex/` branch rather than committing directly to `main`. Preserve unrelated local changes and include only the task's changes in commits and the PR.
- Run the relevant build and checks documented in `README.md`, then push the branch and open or update the PR with a clear description and validation results.
- Obtain an independent review of the PR's current diff through the available PR reviewer or a review subagent. Address actionable findings, push fixes, and repeat review and relevant validation until there are no unresolved actionable findings.
- Before merging, confirm the latest PR commit has been reviewed, all required CI checks have passed, required approvals are satisfied, and the PR is mergeable. A pending or unavailable review/check is not a pass; report the blocker instead of bypassing it.
- Squash-merge the PR into its target branch once those conditions are met. This is the user's standing project preference; do not ask for an additional merge confirmation unless a later user instruction or repository policy requires it.
- Verify the PR was merged and report its link, the squash commit, and validation results. Sync the local target branch only when doing so preserves existing local work.

## Test app cleanup

- Track the bundle paths and process IDs of any Vane test copies launched for the task, including copies in worktrees or temporary build directories.
- After a successful merge, quit every Vane test instance launched for the task before reporting completion. Also clean up these instances when abandoning the task.
- Target only the tracked test instances; leave the user's regular Vane app and instances belonging to other tasks running. Prefer a normal quit, and use a targeted process termination only if an owned test instance does not exit. Do not use blanket commands such as `killall Vane` or `pkill vane`.
- Verify the tracked test processes have exited. If cleanup is blocked, report the remaining instance and reason instead of claiming cleanup succeeded.
