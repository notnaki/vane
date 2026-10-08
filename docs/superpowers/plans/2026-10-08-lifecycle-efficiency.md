# Vane lifecycle efficiency

Work on codex/lifecycle-efficiency in an isolated worktree. Preserve the original checkout's UI work.

1. Inspect tab suspension, WebHost ownership, Little Vane menu/window ownership, KVO and notifications, tasks/timers, and media/PiP cleanup. Reproduce retained objects with weak-reference regressions before changes.
2. Add an opt-in signed browser lifecycle fixture: warm baseline; 100 loaded tab close cycles; 100 loaded Little Vane close cycles (including Space menus); a 200-row parked session; 30-second settling; 60-second idle CPU sample. Record resident memory and weak survivors. Keep fixture profiles isolated and processes bounded/cleaned.
3. Fix only demonstrated ownership/background-work defects, preserving shared-page ownership, active media, draft input, private/pinned/loading/visible/split protections. Re-run regression and baseline fixture after each relevant fix.
4. Run focused XCTest, pure selfcheck and signed WebKit smoke coverage. Record measured results, profiling scope, and remaining limitations in docs. Use Instruments where available.
5. Commit/push, create PR, obtain independent review of latest diff, address findings, await required CI, squash-merge, verify merge SHA, and verify all task-owned app processes exited.
