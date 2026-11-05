# Test app cleanup

- Track bundle path, PID, and start time for every task-launched Vane test copy, including worktree/temp builds. After merging, quit all before reporting completion; also clean up when abandoning the task.
- Target only tracked instances; leave the user's regular app and other tasks' instances running. Never use blanket `killall Vane`/`pkill vane` commands.
- For "Quit Vane?", verify the dialog belongs to the tracked instance and choose "Quit" (or Return in its focused dialog). Never choose "Quit and don't ask again" or change that preference. A quit request alone is insufficient.
- If confirmation blocks quitting or the process remains, the authorized fallback is `kill -TERM <pid>`, then a brief wait/exit check and `kill -KILL <pid>` only as a last resort. Revalidate the PID's executable and launch before each signal to guard against PID reuse.
- Verify exit of every tracked process. Report any remaining instance and blocker; do not claim successful cleanup.
