# Worktree cleanup

- After merging or abandoning a task, remove its worktrees once work is preserved and task-owned test apps have verifiably exited. Include documentation/change worktrees.
- Before removal, inspect `git worktree list --porcelain`, tracked/untracked changes, ignored files, branch/HEAD, related PR status, and processes using the checkout. Age alone proves nothing.
- Preserve the primary checkout, active/open-PR worktrees, and uncommitted/unpreserved work. Remove other tasks' worktrees only on explicit request. Retain uncertain candidates and report why.
- Verify committed work is preserved in the target branch or a merged PR. For squash merges, check local HEAD is included in the PR's final head and preserve its branch or another recovery ref; target ancestry alone is insufficient.
- Use Codex's archive-worktree tool for managed worktrees attached to this chat (recoverable snapshot); separately preserve needed ignored files, which it excludes. Otherwise use `git worktree remove <path>` without force. Discard ignored build products only if confirmed disposable; preserve user data and needed files.
- Never blanket-delete directories, force removal, or delete branches with unpreserved work. Prune stale metadata only after verifying its checkout no longer exists.
- Verify removed paths are gone and absent from `git worktree list`; report removals and retained worktrees.
