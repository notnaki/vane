# Project workflow

Read the linked instructions before the relevant phase; load only what applies to the task.

- **Before changing code:** Open a new task worktree.
- **Before waiting or yielding:** Refresh each blocker's status and continue immediately if it is resolved. Ensure completion monitoring covers the actual dependency; a PR-only watch does not cover a separate `main` run.
- **Any project change:** [PR workflow](docs/agents/workflow.md). Default to implementation, validation, independent review, and squash-merge unless the user specifies another stopping point.
- **Choosing/running validation, investigating failures, or assessing CI:** [Validation and CI](docs/agents/validation.md).
- **Mandatory before any release work:** Read [Release policy and procedures](docs/RELEASING.md) in full before choosing a release version, creating or pushing a release tag, dispatching the release workflow, or publishing a release. Follow its version format, patch/minor/major rules, procedures, and release checklist; do not rely on memory or prior releases.
- **Changing UI interactions or state:** [UI motion](docs/agents/ui-motion.md).
- **Writing/running native regression fixtures:** [Native fixture readiness](docs/agents/native-fixtures.md).
- **Before launching Vane test copies:** [Test app tracking and cleanup](docs/agents/test-apps.md). Follow through after merging or abandoning the task.
- **Before creating or removing task worktrees:** [Worktree preservation and cleanup](docs/agents/worktrees.md). Clean up after merging or abandoning the task, including documentation worktrees.
