# Vane app imagery

The `vane-*-dark.png` files are window captures of the running native
Vane app on macOS 26, taken on 6 October 2026. They use an isolated demo data folder,
dark Spaces, and original Fieldnotes example pages. They contain no personal browsing
data. The example pages are sample website content; the browser UI is Vane itself.

All screenshots are encoded as actual PNG files. The three native display captures
previously contained JPEG data despite their filenames; their white outer-corner
matte is now transparent, including its antialiased fringe. App content, dimensions,
and all pixels outside that corner matte are preserved. Re-encoding cannot recover
detail already lost to the original JPEG compression. Historical audit screenshots
are also re-encoded as PNG, with their decoded pixels unchanged.

Website layouts crop the top 84 pixels to omit the macOS capture indicator and cursor.
The rest of each app capture is displayed without redrawing, recoloring, or changing
its proportions. Little Vane is a separate native window, composited above the
Work Space capture with CSS.

`display.html` provides a reusable, plain charcoal setting. Open it with `?view=spaces`,
`?view=split`, or `?view=little`; the default is Spaces. The `vane-display-*.png`
exports are rendered from these layouts and can be used in websites, slides, and
other product displays. Keep the source captures for future crops and layouts.

The website uses brief transitions and disables them with Reduce Motion. No generated
or reconstructed app interface is used in these assets.
