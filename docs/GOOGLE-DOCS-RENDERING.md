# Google Docs canvas blur

On macOS 27.0.1 (Safari 27.0.1), an affected live document reported
`devicePixelRatio=2` and `visualViewport.scale=1`. Its document canvases had
408 × 528 backing pixels displayed at 816 × 1056 CSS pixels, while the menus
remained sharp. No document text or identifiers are retained here.

Vane advertised `Version/26.0`. Google Docs' `kix_core` script, inspected on
2026-10-08, uses native devicePixelRatio for Safari 26.4 and later. For older
Safari, it multiplies DPR by outerWidth/innerWidth snapped to a list of zoom
levels whose minimum is 0.25. A standalone native WKWebView on this Mac reported
outerWidth=0 and innerWidth=816. That produces a density of 0.5 instead of 2,
explaining the exact live canvas dimensions.

The default Safari identity now reads the installed Safari version, falling
back to macOS major/minor numbering when application metadata is unavailable.
Existing saved copies of the former default resolve to the current identity.
Choosing Safari default persists an automatic choice rather than a fixed
version. Explicit Chrome, Firefox, and iPhone selections are preserved. The
Advanced Settings picker uses the same resolution rule.

Validation uses a nonpersistent real WKWebView fixture with the observed Docs
zoom calculation. Before the fix it reproduced 408 × 528 at 100% and
612 × 792 at 150%; after the fix it rendered at 1632 × 2112 and 2448 × 3168
respectively. Tests also cover the saved old default, alternative identities,
Safari updates newer than macOS, invalid metadata, and selecting default again.
PageCaptureTests cover native pixel cropping of a scrolled, zoomed page.

This is a locally controlled reproduction of the Google Docs decision, not a
claim that the updated app has been validated against the user's authenticated
document. An already loaded document needs a reload after running the updated
Vane build. The compatibility fix targets current WebKit's native zoom-aware
DPR; the older Docs calculation remains applicable on macOS/Safari 26.0–26.3.
