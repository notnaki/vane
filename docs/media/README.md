# Vane app imagery

The `vane-*-dark.png` files are full native window captures of Vane on macOS 27,
taken on 9 October 2026 from source revision `37abf63`. They use an isolated demo
data folder, a dark Work Space, and local Fieldnotes example pages. They contain
no personal browsing data. The example pages are sample website content; the
browser UI is Vane itself. Developer Mode is disabled for the local demo host.

All screenshots are encoded as actual PNG files. The three native captures retain
the transparent rounded corners provided by macOS. They include the traffic lights
and toolbar controls, with no top crop, capture indicator, cursor, or white corner
matte. Traffic lights retain their native active or inactive appearance. App pixels
are not redrawn or retouched. Historical audit screenshots were re-encoded from their
previous JPEG data as PNG, with their decoded pixels and dimensions unchanged;
this cannot recover detail already lost to JPEG compression.

Capture a demo window directly with `screencapture -x -o -l <window-id> -t png <output>`.
`-o` excludes the window shadow; PNG preserves its transparent outer corners.
Keep the complete window when updating these assets. Website layouts scale each
capture proportionally and retain the full top controls. Little Vane is a separate
native window, composited above the Work Space capture with CSS.

`display.html` provides a reusable, plain charcoal setting. Open it with `?view=spaces`,
`?view=split`, or `?view=little`; the default is Spaces. The `vane-display-*.png`
exports are rendered from these layouts and can be used in websites, slides, and
other product displays. Keep the source captures for future layouts.

The website uses brief transitions and disables them with Reduce Motion. No generated
or reconstructed app interface is used in these assets.
