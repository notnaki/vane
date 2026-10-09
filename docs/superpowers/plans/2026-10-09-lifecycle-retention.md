# Lifecycle retention investigation plan

**Goal:** Reproduce and fix demonstrated retained Vane objects or abandoned preview work without changing tab ownership, draft/media protection, or navigation recovery.

**Architecture:** Keep Find state owned by the window's TabStore if its global registry demonstrably retains closed sessions. Keep the preview's reusable WebView, while ensuring its existing blank-document cancellation actually unloads a dismissed document.

**Constraints:** Isolated codex branch/worktree; isolated data; serialize builds and profiling using `/tmp/vane-performance-window.lock`; equivalent 30-second settling; report Vane ownership separately from WebKit caches; focused validation without routine CI performance thresholds.

- [x] Reproduce Find retention using weak session references across 100 stores and 30-second settling.
- [x] Reproduce preview cancellation and cached replacement using a localhost timer document, 30-second settling, and a 3-second callback sample.
- [x] Implement only fixes supported by those reproductions, preserving session continuity while stores are live and preview cache/WebView reuse.
- [ ] Repeat equivalent measurements; run lifecycle, Find, previews, shared ownership, suspension/draft/media regressions and signed browser lifecycle fixture.
- [ ] Record environment, measurements, limitations and tracked process exits; open PR, independently review current head, satisfy CI and squash-merge.

**Review focus:** Cached preview replacement must unload the previous document; blank-document callbacks must not satisfy a new request's paint/summary gates; Find state must remain per store and survive parking; shared pages must survive closing another owner; suspension must preserve protected drafts and active media.
