# Navigation history save recovery

Navigation callbacks now retain failed HTTP(S) visits and title updates in the
existing ordered pending-write log. Later changes queue behind the failure,
including a subsequent Clear History, so retry cannot resurrect deliberately
cleared visits. Visit timestamps are captured at navigation, not at retry.

History displays a save-failure message with **Retry Save**. The active regular
profile can also receive a retry toast. A separate save-state notification leaves
the existing history-change notification tied to published database changes.
Headless Store consumers do not require an NSApplication to report failure.

Quit and backup already drain this log and refuse to continue when it cannot be
saved. Successful enqueue is not durable storage. Pending operations live in
memory: a crash or forced termination before a successful retry can lose them.
Other UserDefaults settings retain their existing persistence behavior.

## Validation on 2026-11-10

Synthetic SQLite triggers reject visit inserts and title updates, then permit
retry. Two new regressions verify original visit times, failed retry retention,
ordered suffix replay, no duplicate drain, and clear-after-failure ordering.
Before implementation these two tests produced nine assertion failures.

The first green attempt exposed a headless crash in the existing toast path:
Windows.current consulted an absent NSApplication. Store now checks NSApp before
accessing windows. After this repair, the focused wrapper completed **74 tests,
zero failures**, with cleanup successful:

```sh
python3 scripts/run-native-tests.py --jobs 2 --filter 'HistoryPersistenceTests|ImportWorkerTests|HistorySearchTests|HistorySearchIndexTests|BrowserDataFidelityTests'
```

Evidence is retained under `/tmp/vane-readiness-history-20261110/`, including the
original red run and headless crash. No windows, activation, input, capture,
personal profiles or real account data were used. Foreground History interaction,
physical disk failure, macOS 26 and notarized builds remain separate checks.

## Background-batch review follow-up

Three additional regressions reproduced six assertion failures before repair:
retry feedback escaped into another profile/private window, and zero-progress
retries emitted committed-history notifications. Save/rejection notices now capture
a matching nonprivate owner explicitly. Failed replay publishes history changes
only if a prefix committed; save-state feedback remains separate.

The combined blocker/history/import/search/data-fidelity wrapper passed 138 tests
with zero failures and successful cleanup. This includes all blocker IO fixtures
and the three new failed-write tests. The ownership regression uses real, unshown
windows and verifies they remain invisible and non-key; no activation, input or
capture is used. Red/green evidence is retained under
`/tmp/vane-background-limitations-batch-20261110-evidence/`.
