# Library inline filters — 2026-11-10

Native 246-point Library headers rendered on macOS 27.0.1 with Xcode 27.0.
`before.png` uses the unchanged LibraryHead from base commit
`5cd5979a883b4fb20ed7c827f3cecaa003d74757` in a temporary native fixture.
`search.png`, `panel.png`, and `private-panel.png` use
`LibraryFilterRenderingTests` with synthetic profiles and an opaque window
background for capture. Set `VANE_LIBRARY_FILTER_CAPTURES` to an existing
directory when running that test to regenerate the current captures.

The focused validation passed 25 tests, including regular/private rendering,
search focus restoration, profile/search/status intersections, archive cache
identity, publication behavior, download ownership, and Reading Queue aggregation.
The native wrapper also verified post-exit cleanup. These are scoped component
checks; no signed app bundle or external account was required.
