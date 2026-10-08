# UI responsiveness and interaction continuity

The user's brief authorizes two phases in this session, preserving the existing
visual design and taking the final diff through independent review and squash merge.

- [x] Capture the latest-main release executable, run the signed smoke fixture,
  and exercise small/large isolated native fixtures (200 tabs, 10 Spaces, 10,000 visits).
  Retain identical fixture generation and interaction sequences for comparison.
- [x] Measure input work, native layout, run-loop delays and process resources.
  Attempt Time Profiler, Animation Hitches and allocation captures; distinguish
  unavailable measurements and WebKit/system work from Vane-owned work.
- [x] Investigate ownership/visibility timeouts (195 baseline smoke assertions pass,
  historical timeouts did not reproduce). Keep meaningful final-owner,
  profile-isolation, draft-preservation and traffic-light assertions.
- [x] Add failing regressions for confirmed defects before fixing them. Prioritize
  blocking work, latest-intent handling, interrupted completion callbacks and
  motion-policy omissions. Use Look/Motion timings and existing native controls.
- [x] Repeat fixtures, native keyboard/pointer interactions, resizing, and motion
  reduction. Record visual examples separately from measured improvements.
  Remaining native drag, system Reduce Motion and matched animation capture gaps
  are explicitly recorded in `docs/UI-RESPONSIVENESS.md`.
- [ ] Run relevant XCTest, release pure checks and signed smoke. Review current PR
  diff independently; fix findings, await required CI, squash merge, verify merge.
- [ ] Quit and verify exit of every tracked test app; retain evidence and honest gaps.

Review focus: rapid reversals during landing; stale callbacks after profile/window
changes; no hidden WebView creation; active media and draft preservation; reducing
motion mid-transition without stranding visual or keyboard state.
