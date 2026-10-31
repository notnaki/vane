# Full-screen onboarding implementation plan

**Goal:** Replace the small tutorial sheet with a tasteful full-screen native welcome inspired by Arc's personalization and Zen's focused setup.

**Architecture:** Keep first-install detection and completion semantics. An owned borderless window covers the initial browser's screen, temporarily hides Dock/menu bar, and restores presentation options and browser focus on completion. SwiftUI adapts to screen dimensions and uses the existing motion policy.

**Tech stack:** Swift, AppKit, SwiftUI; existing Space themes and Search engines.

## Direction and constraints

User feedback: the current welcome is not fullscreen or tasteful. Use warm paper, restrained ink, native serif display type, generous space, and brief transitions. Keep the shipped V mark. Welcome → Space color → search engine → browsing. Choices apply through existing production settings; no network assets or account gate. Back, skip, Return, and Escape work. Interrupted onboarding remains pending; existing installs never see it. Incoming links remain intact. Honor Reduce Motion and Battery Saver. Scope is onboarding only.

## Tasks

- [ ] Replace sheet ownership with screen-covering presentation; validate sizing, focus, restoration, and incoming-link handoff.
- [ ] Build responsive welcome/setup screens and persist selected Space color and search engine through existing APIs.
- [ ] Run focused FirstLaunch tests, build bundled app, visually check complete/back/skip and reduced motion, record a video of the real app.
- [ ] Open PR, independently review current diff, fix findings, run required CI against latest main, squash merge, verify and clean task app/worktree.

## Review focus

Presentation options restored once; window owner retained until dismissed; multi-display sizing and small displays; no forced navigation over incoming URLs; no changes to regular user data; visible keyboard focus and sufficient text contrast.

## Progress

Research: inspected current FirstLaunch.swift, Arc onboarding captures, and Zen's current welcome CSS/localized steps. Native screen recording will document the working app.
