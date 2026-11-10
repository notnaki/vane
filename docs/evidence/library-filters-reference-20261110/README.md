# Approved Library reference preview — 2026-11-10

The user approved this appearance after reviewing the native screenshot and
6.6-second recording. The source change is commit
`57d2cd77214c3e7d5cb6b58e16d0344b5c824d9c`.

The Library uses rounded SF lettering: 14pt controls/titles, 13pt group headings
and subtitles, a 304pt list column, 36pt search/Done controls, 32pt profile chips,
56pt rows, and 24pt thumbnails. Additional section filters and actions remain in
More, leaving Profiles directly above the results.

`approved-panel.png` is a frame from the native ScreenCaptureKit recording;
`approved-demo.mp4` shows Filter opening, selecting school, and Done returning to
search. The preview uses synthetic profiles/files and an opaque neutral dark
window background. A regular browser window inherits its Space theme.
`approved-search.png` and `private-panel.png` come from the native render fixture.

Validation on macOS 27.0.1 / Xcode 27.0:

- 63 focused tests: 1 optional performance sample skipped, 0 failures; cleanup passed.
- After moving secondary filters into More: 9 focused tests passed; cleanup passed.
- After final expanded-panel spacing: 2 native render/focus tests passed; cleanup passed.
- Independent final source review: no findings.
- The user said “looks good” after viewing these captures.

The individual PR remains subject to the integration coordinator's serialization
gate. This evidence commit skips individual hosted CI; a fresh combined review
and required CI remain necessary for the later batch. No merge is authorized here.
