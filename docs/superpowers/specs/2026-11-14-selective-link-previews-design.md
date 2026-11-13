# Selective link previews

The reported GitHub folder/branch popovers result from an unconditional 190ms hover gate. Keep normal navigation quiet. Match Arc Max's documented interaction: automatic previews on search-result/content links on Google, DuckDuckGo, Bing, X/Twitter, Threads and Hacker News; Shift-hover explicitly previews other web destinations. Exclude same-document links, downloads and modified clicks. Use structural result/article selectors and external destinations so search controls, profiles, comments and navigation do not start speculative work.

Replace the fixed 350pt card and continuously changing miniature page with a compact loading row, a single settled image, restrained typography and a bounded content card. Preserve source-tab ownership, cancellation, ephemeral session handling, cache and AI policy. Respect reduced motion. Keep snapshots bounded by the existing deadline and do not delay metadata or summaries.

Approaches considered: disabling previews loses useful intentional previews; a longer universal dwell still loads every navigation destination. Selective triggers address the wasted work at its source. A single settled snapshot avoids repeatedly presenting partially styled layouts without introducing another metadata-image network pipeline.

References: https://arc.net/max (Shift-hover); https://tidbits.com/2023/10/06/arc-web-browser-introduces-focused-ai-features/ (contemporary automatic-site list). The original Arc help URL returns 404; Wayback returned a temporary outage and snapshot lookup timeout during this task. The structural link filters and compact visual treatment are implementation choices for this request, not claimed copies of Arc internals.

Local primary evidence: the installed Arc.app binary contains the hover selectors `[data-testid=tweetText] a[role=link][target=_blank]`, `[data-testid='card.wrapper'] a[role=link]`, `a[role=link][rel='nofollow noreferrer'][target=_blank]`, `.title .titleline > a`, and `g-section-with-header a [role=heading]`, plus the settings copy explaining automatic previews on certain websites and Shift-hover elsewhere. No Arc code or resources are copied into Vane.

## Added presentation requirements

The user explicitly requested typed text, card growth as it is written, no unused description space, and animated entry and exit. Use the visible text's intrinsic height, including at intermediate typing steps, rather than fixed phase heights. Reveal descriptions and streamed summaries in small grapheme-safe steps, preserving cumulative prefixes and resetting corrected/retracted text. Bound backlog so a completed response does not take seconds of artificial delay to catch up. Cancel the reveal with the card and reveal instantly under Reduce Motion/Battery Saver. Use brief fade/scale/vertical travel for entry and exit and animate height changes with the existing motion-speed policy.

Independent review also identified two renderer cases: retry a blank first capture within the original paint deadline, while publishing only one useful frame; and revalidate the navigation/document after each snapshot or session await so an adopted client redirect cannot publish old pixels.

Final corner treatment: retain the outer card’s 12-point rounded corners. The preview image has a rectangular clip and no independent corner radius, as clarified by the user.
