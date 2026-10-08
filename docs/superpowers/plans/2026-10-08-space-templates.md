# Space templates implementation plan

Execution: native in the isolated codex/space-templates worktree; independent review at the end, as requested by AGENTS.md.
Spec: docs/superpowers/specs/2026-10-08-space-templates-design.md

1. Add SpaceLayout and WorkspaceTemplate codecs with profile-scoped atomic storage. Write failing tests for unsafe addresses, nested folder identity, duplicate addresses, authentication refusal, corrupt files and failed mutations. Implement and run focused tests.
2. Add optional Space.layout and live capture/restore integration. Preserve fresh row/folder identities and per-row names. Persist split weights through Split.Saved. Test initial restore, disk switching, legacy fallbacks, locked reconstruction and session restoration.
3. Add the native template sheet and Space/creation menu routes. Capture and revalidate folder authentication, show protected previews only with grants, keep errors retryable, and respect motion policy. Test operations with real persisted fixtures and render the sheet on macOS 27.
4. Document behavior and backup contract; integrate with the concurrent backup implementation once available. Run build, relevant regressions and pure checks. Push/open PR, obtain independent review, fix and revalidate, wait for CI, squash-merge, verify commit and quit tracked test instances.

Review focus: changed sources during authentication; repeated URLs with different names; cancelled/failed disk writes; corrupt profile/Space lists; relock while a preview is visible; backup version compatibility.
