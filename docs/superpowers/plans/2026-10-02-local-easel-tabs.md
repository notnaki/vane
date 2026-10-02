# Local Easel Tabs Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Open local Easels inside Vane as persistent native browser tabs, following Arc's canvas/tab interaction.

**Architecture:** Reuse the existing EaselStore and native editor. A profile-scoped `vane://easel/<board UUID>` address identifies native tab content and travels through existing pinned-tab, Space, and session persistence. Browser actions and Library open boards in the originating browser window; no separate Easel window is needed.

**Tech Stack:** Swift, SwiftUI, AppKit, existing JSON board storage and XCTest.

**Spec:** The user approved a local canvas with notes, images, links, drawings, static webpage captures and autosave, then requested research and implementation. Research: https://resources.arc.net/hc/en-us/articles/19231142050071-Easels-Capture-Create. Latest main already implements the canvas in a separate window, so this change integrates that existing subsystem into tabs.

## Constraints

- Keep unrelated edits in the original checkout untouched; work on codex/local-easels.
- Each tab refers to one board; closing a tab never deletes its board.
- New boards are pinned in the current Space. Library remains the board catalogue.
- Internal addresses do not create WebKit pages or expose other profiles' boards. Private windows cannot open or save Easels.
- Preserve current editing, undo/redo, export, import, captures and save failure reporting.
- Route board links to ordinary browser tabs; pause live views when the Easel leaves the visible canvas.

## Work

- [ ] Add failing native tab navigation/restoration and palette regressions.
- [ ] Implement strict internal addresses and native tab lifecycle; bypass webpage-only behavior.
- [ ] Embed the existing editor with native responder support; make duplicate/import open their own board tabs.
- [ ] Route File, Library, footer plus and command palette actions through the originating window.
- [ ] Verify focused regressions, the full XCTest suite, pure/full checks, debug/release builds and packaging checks documented in README.
- [ ] Exercise a uniquely identified, isolated test app in the UI, then quit and verify its exact process exits.
- [ ] Push a PR, attach it, obtain an independent review of the latest diff, fix findings, wait for required CI and squash-merge.
