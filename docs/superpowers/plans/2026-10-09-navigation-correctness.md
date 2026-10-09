# Navigation correctness implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep Vane chrome, history and document state consistent through navigation and tab lifecycle races on macOS 27.
**Architecture:** Keep WebKit as the back/forward authority. Bind delegate work and async document work to the owning live view and navigation/document identity; bind simulated-page history exclusion to its navigation rather than the next completion.
**Tech Stack:** Swift, WKWebView, XCTest, loopback Network fixtures.
**Spec:** User navigation audit request in this chat.

## Constraints
- Preserve security policies and WebKit popup configuration/request bodies.
- Use isolated codex/ worktree; coordinate release/suspension/process recovery edits with reliability tasks.
- Reproduce failures before fixing; exercise actual WebKit with controlled local fixtures.
- Review current PR commit, pass required CI, squash merge, clean owned processes.

## Review focus
- Old callbacks after replacement, suspension or teardown must be inert.
- Same URL reload must invalidate async document results.
- Synthetic failures must not enter successful history or suppress the next real visit.
- SPA routes and fragment back/forward must agree with displayed location.
- Reload/back/forward after POST must not silently repeat writes.

## Tasks
- [x] Establish baseline; add held responses, redirects, interrupted transport, forms, auth/download fixtures.
- [x] Reproduce stale navigation completion/failure, same-document history, synthetic recovery, cancelled navigation and POST replay defects.
- [x] Implement focused navigation identity/history/confirmation fixes and rerun failures.
- [x] Exercise pending tab switch/move/close, stop/reload/back/forward, popup/download/auth paths.
- [ ] Run focused and broad validation, document exact coverage, independent review and fixes, required CI and squash merge.
