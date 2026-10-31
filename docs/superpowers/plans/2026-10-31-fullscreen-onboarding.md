# Full-screen onboarding implementation plan

**Goal:** Replace the small tutorial sheet with a tasteful full-screen native welcome inspired by Arc's personalization and Zen's focused setup.

**Architecture:** Keep first-install detection and completion semantics. An owned borderless window covers the initial browser's screen, temporarily hides Dock/menu bar, and restores presentation options and browser focus on completion. SwiftUI adapts to screen dimensions and uses the existing motion policy.

**Tech stack:** Swift, AppKit, SwiftUI; existing Space themes and Search engines.

## Direction and constraints

User feedback: the current welcome is not fullscreen or tasteful. Use warm paper, restrained ink, native serif display type, generous space, and brief transitions. Keep the shipped V mark. Welcome → Space color → search engine → browsing. Choices apply through existing production settings; no network assets or account gate. Back, skip, Return, and Escape work. Interrupted onboarding remains pending; existing installs never see it. Incoming links remain intact. Honor Reduce Motion and Battery Saver. Scope is onboarding only.

## Tasks

- [x] Replace sheet ownership with screen-covering presentation; validate sizing, focus, restoration, and incoming-link handoff.
- [x] Build responsive welcome/setup screens and persist selected Space color and search engine through existing APIs.
- [x] Run focused FirstLaunch tests, build bundled app, visually check complete/back/skip and reduced motion, record a video of the real app.
- [ ] Open PR, independently review current diff, fix findings, run required CI against latest main, squash merge, verify and clean task app/worktree.

## Review focus

Presentation options restored once; window owner retained until dismissed; multi-display sizing and small displays; no forced navigation over incoming URLs; no changes to regular user data; visible keyboard focus and sufficient text contrast.

## Progress

Research: inspected current FirstLaunch.swift, Arc onboarding captures, and Zen's current welcome CSS/localized steps. Native screen recording will document the working app.

Validation: six focused native tests and cleanup passed; pure selfcheck passed; signed app packaged. Real-app completion, Back, persistence, restart, Battery Saver, and Escape/initial-URL preservation checked. Full-screen dark captures and 800×600 light layout inspected. A 38-second MP4 is saved outside the worktree. Independent review of d2ff535 found no actionable issues. Final adjustment groups the shortcut keys into one accessibility element to avoid duplicate announcements. Required CI and merge remain pending.

CI investigation: integrated run 41231768323 failed the existing offline-navigation fixture at NavigationWebKitTests.swift:218. The fixture requested asynchronous listener cancellation without admitting its terminal callback, and queued connection deliveries could revive it after stop. A deterministic regression failed locally and in all three macOS 26 baseline preflight attempts (run 41233876662), with cleanup passing. The fixture now revokes late connection/receive work and waits for terminal cancellation before offline navigation; original outcome/history/recovery assertions and deadlines are retained. Five focused cases passed in all three repaired macOS 26 preflight attempts (run 41234101742), with primary and cleanup status 0. Every original failure and sample is preserved outside the worktree. The temporary preflight workflow stays on its separate recovery branch.

Merge constraint: immediately before merging, recheck main HEAD and all CI runs on main. Do not merge while any main CI run is unfinished; never cancel one to unblock merge. Full required CI must pass on the latest integrated PR head, independently reviewed with approvals and mergeability satisfied.
