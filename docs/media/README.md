# Vane app imagery

The `vane-*-dark.png` files are full native window captures of Vane on macOS 27,
taken on 23 October 2026 from source revision `4ba0926`. They use disposable
`VANE_DATA_DIR` profiles with no personal browsing data or signed-in accounts.
The browser UI and the public websites are rendered by Vane itself:

| Capture | Website content |
| --- | --- |
| `vane-spaces-dark.png` | [Wikipedia: Architecture](https://en.wikipedia.org/wiki/Architecture) in the Explore Space, with Wikipedia, GitHub, and MDN favourites. |
| `vane-split-dark.png` | [Wikipedia: Architecture](https://en.wikipedia.org/wiki/Architecture) and [Industrial design](https://en.wikipedia.org/wiki/Industrial_design) side by side. |
| `vane-little-dark.png` | The [MDN Web Docs homepage](https://developer.mozilla.org/en-US/) in a native Little Vane window. |

These replace the former fictional Fieldnotes pages. Wikipedia and MDN retain
their own branding, content, and attribution; their appearance here illustrates
browsing in Vane and does not imply endorsement. Wikipedia text is available under
[CC BY-SA 4.0](https://en.wikipedia.org/wiki/Wikipedia:Text_of_the_Creative_Commons_Attribution-ShareAlike_4.0_International_License);
see the linked articles and individual image pages for full credits and terms.

All screenshots are actual PNG files. The native captures retain the transparent
rounded corners provided by macOS. They include the complete traffic lights and
toolbar controls, with no top crop, recording badge, cursor, or white corner matte.
Traffic lights retain their native inactive appearance. App and website pixels are
not redrawn or retouched. Historical audit screenshots are separate evidence and
have not been replaced.

Capture a demo window directly with `screencapture -x -o -l <window-id> -t png <output>`.
`-o` excludes the window shadow; PNG preserves its transparent outer corners.
Verify the window belongs to the isolated test process. A computer-control session
can put a macOS recording badge over the traffic lights: finish configuring the
profile, quit that test process, and relaunch it without attaching computer control
before capturing. Inspect every final capture for overlays and fully loaded content.
Keep the complete window when updating these assets. Website layouts scale each
capture proportionally and retain the full top controls. Little Vane is a separate
native window, composited above the Explore Space capture with CSS.

`display.html` provides a reusable, plain charcoal setting. Open it with `?view=spaces`,
`?view=split`, or `?view=little`; the default is Spaces. The 1280 × 720
`vane-display-*.png` exports are rendered from these layouts and can be used in
websites, slides, and other product displays. Regenerate all three exports when
updating the source captures, and bump the image query versions in `index.html`,
`features.html`, and `display.html` so returning visitors receive the new images.

The website uses brief transitions and disables them with Reduce Motion. No generated
or reconstructed app interface is used in these assets.
