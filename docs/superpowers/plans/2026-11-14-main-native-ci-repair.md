# Main native CI repair

Base: `de19eb16063a59be0182461aaa05624f33532185`. Failed main run: `43525420028`.

1. Repair native-result reuse's stale routing job name. First demonstrate failure with actual workflow job names, then add a contract test against the workflow so future renames cannot silently disable reuse. Keep all exact-tree, current-base, same-repository, completed-job proofs intact.
2. Coordinate the exact shared snapshot-helper hunk with its owner. The occlusion fixture currently allows recovery before the injected native occlusion is observed. Admit that prerequisite under the existing deadline before enabling recovery; preserve the still-key, real-occlusion and recovered-visible assertions.
3. Run source tests locally; run native validation only on hosted macOS 26. Predetermine three focused repetitions covering all snapshot-readiness cases and related presentation fixtures, retain all attempts and require cleanup checks. Do not rerun unchanged native failures as qualification.
4. Obtain independent source review, complete required PR CI, recheck current main and every unfinished main run, then squash-merge. Verify main's reuse decision and resulting checks. Send the public qualified commit/diff and CI result to the integration owner.

Ownership: this task owns the reuse repair and reviewed public fixture repair only. Other owners' worktrees/branches remain untouched. Shared helper edits require exact-hunk agreement. No local native, input or capture work is planned.

Prior validation caveat: PR679's earlier local `/tmp/vane-ci-fixture-preflight-{1,2,3}.log` executions overlapped another owner's build (22:14:25–22:15:03 UTC); they were not exclusive or uncontended. PR679's final qualification was independently hosted.

## Validation record

- Reuse regression reproduced before the fix: the actual routing name made identical-tree reuse return `None`; the workflow contract reported exactly the stale/actual name difference.
- After the one-name repair: 18 reuse tests, 23 change-scope tests and 12,333 workflow aggregate cases passed. Independent source review found no actionable issue.
- Read-only replay against the real failed main run `43525420028` and squash `de19eb16` returned `native_reused=true`, selecting successful PR run `43522729887`. The original decision returned false. Public evidence is retained under `/Users/nuh/.t3/userdata/artifacts/main-native-ci-repair-20261114/`.
- Native repair and hosted qualification remain pending; these source results do not qualify the occlusion fixture.
