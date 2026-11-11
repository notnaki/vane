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


## Current website captures — 10 November 2026

The five primary website pages use these actual native captures:

| Capture | Content |
| --- | --- |
| `vane-varied-spaces-v1.png` | NASA Science’s Mars page in a lilac Explore Space. |
| `vane-varied-split-v1.png` | NASA and a Creative Independent interview side by side. |
| `vane-varied-little-v1.png` | Figma’s homepage in a native Little Vane window. |
| `vane-command-v1.png` | Vane’s address/search bar over NASA’s Mars page. |
| `vane-library-v1.png` | Native Library with three disposable demo Spaces. |
| `vane-home-spaces-v3.png` | Apple’s MacBook Pro page with Apple, GitHub, and Linear favourites and a Figma pin. |

These full, unretouched PNGs were captured from installed Vane 0.1.0 build 612;
its exact source revision was not verified. Main windows are 2560 × 1680 and
Little Vane is 2000 × 1400. They preserve transparent native corners, complete
toolbar controls, and genuine active, resting colored-outline traffic lights.
The newer pages reference these native files directly without extra CSS corner
rounding. The older Wikipedia/MDN images and display exports remain historical
assets and are not referenced by the five primary website pages.

The homepage sidebar keeps the complete native window fixed. Selected controls
are magnified inside a rounded annotation using a second copy of the same
image; source pixels are unchanged. Spaces and Split View captures share native
window bounds, theme, sidebar width, and loaded NASA page; the page responds
naturally to the split layout.

Captures used isolated disposable profiles in uniquely identified app copies
with launchers enforcing `VANE_DATA_DIR`. Tracked processes were verified exited
and their disposable apps/profiles removed. NASA, The Creative Independent,
Figma, Apple, GitHub, and Linear retain their own branding and content. Their
appearance demonstrates ordinary browsing and does not imply endorsement.

The self-hosted Cormorant Garamond variable font comes from the Google Fonts
repository (`ofl/cormorantgaramond`). Its SIL Open Font License is preserved in
`../fonts/OFL.txt`.


## Website identity

`../app-icon.png` is a byte-identical copy of the original blue glass catalogue
render at `AppIcons/Previews/Normal.png`, used as the website’s primary logo.
The installed app separately supports a user-selectable Dark finish; the website
does not infer a visitor’s app-icon preference.

The homepage Vane wordmark uses Pinyon Script from the Google Fonts repository
(`ofl/pinyonscript`), self-hosted in `../fonts/pinyon-script.ttf` with its SIL Open
Font License in `../fonts/Pinyon-OFL.txt`. It is lettering for the website, not
a replacement for the native app icon.

`sunlight.jpg` is an AI-generated decorative leaf-shadow image created on
10 November 2026. The homepage blends it into a dark lilac backdrop. It contains
no app UI; product windows remain unmodified native app captures.

## Homepage session video — 11 November 2026

`vane-session.webm` and its `vane-session.mp4` fallback contain a 20-second,
silent recording of installed Vane `0.1.1-nightly.20261110.1` (build 623).
It switches from the NASA Mars page to a Studio Space, opens Linear and Figma
side by side, and brings a smaller Little Vane article forward for a quick read.
The pointer uses varied curved paths and brief corrections; input is scripted
against the disposable instance. macOS menus and desktop chrome are excluded.

The recording uses a separate data directory and uniquely identified app copy.
The app binary is unchanged (SHA-256
`16eb83e96deec152a02f0605b44e7c308cc9d82f6d479e0ab1aecdce3966bc52`).
Automatic Picture in Picture is disabled only in that demo instance to keep
Figma’s page video from floating over the recording.

Exports are proportionally scaled to 1600 × 1050 at 30 fps. The WebM’s alpha
comes from the actual native window silhouette in `vane-session-poster.png`;
the MP4 uses the same silhouette over a dark surface. There is no additional
CSS corner rounding or redrawn app UI. The homepage pauses playback offscreen,
preserves a visitor’s manual pause, and leaves playback manual with Reduce Motion.


## Delivery optimisation — 11 November 2026

The primary pages use proportional WebP derivatives of the native PNG captures
at 768, 1536, and 2304 pixels, selected through responsive `srcset` values.
The original PNGs remain preserved. Capture derivatives retain their native
Display P3 ICC profiles and alpha corners; no controls are redrawn or cropped.
The homepage magnifier uses the 1536-pixel source for legibility.

`vane-session-poster.webp` is a 1600-pixel derivative of the native video poster.
`sunlight.webp` compresses the decorative background. The small `app-icon-*.webp`
files are proportional derivatives of `../app-icon.png`, whose original bytes
remain unchanged. Cormorant and Pinyon are delivered as WOFF2 using the same
font data and existing SIL Open Font Licenses; original TTFs are preserved.
