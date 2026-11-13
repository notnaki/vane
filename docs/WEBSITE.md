# Website, search, and shared links

[Documentation index](README.md) · [Current development](CURRENT-DEVELOPMENT.md)

The public site uses **https://vane.so/**, set by `docs/CNAME`. Its five primary
pages are static HTML in `docs/`: the homepage, features, guide, download page,
and privacy policy. Keep the download destination on published GitHub releases;
the guide and feature descriptions follow current `main` and say when published
builds can differ. Updating this site does not publish an app release.

## Search identity and discovery

- Use `https://vane.so/` as the homepage canonical URL, and the matching absolute
  URL for each other primary page. Use the same domain in Open Graph metadata.
- The homepage includes `WebSite` and `SoftwareApplication` JSON-LD describing
  Vane as the free, open-source native Mac browser. No ratings, review counts,
  release version, or shipping date are invented for search markup.
- `sitemap.xml` lists the five canonical pages; `robots.txt` announces it and
  leaves the main site and its image assets crawlable. Archived designs, tests,
  and rendering-source pages are outside the advertised public navigation.
  Robots rules are crawler guidance, not access control or guaranteed removal.
- Keep the actual page title, description, headings, icon, and project identity
  consistent. Vane is not the unrelated anti-detect browser or search project
  that may appear for similar queries.

Google chooses indexing, ranking, result titles, site names, and images. Metadata
and a sitemap do not guarantee a position or an immediate result. A verified
owner should add the domain or URL-prefix property in
[Google Search Console](https://search.google.com/search-console), submit
`https://vane.so/sitemap.xml`, and request indexing of the homepage through URL
Inspection. Domain ownership verification needs access to the domain's DNS;
a URL-prefix property can use a verification HTML file or tag when offered.
Do not claim submission or verification without completing it in that account.

See Google's [site-name guidance](https://developers.google.com/search/docs/appearance/site-names)
and [sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap).

## Messages and social previews

All five pages provide `og:title`, `og:description`, a page-specific `og:url`, and
the absolute HTTPS share-image URL directly in their original HTML. They also
provide a large-image Twitter card and the 180px Apple touch icon. Preview
clients do not need JavaScript, login, or a special user agent.

`media/vane-share-20261113.png` is a **1200 × 630** PNG composed from the approved
Vane lettering, original app icon, and a genuine native browser capture. The
editable HTML source is `media/share-card.html`; its product image keeps the
native window shape. Render that source at 1200 × 630 with device scale 1 and
the self-hosted fonts loaded. Update the dated image URL in all five pages when
replacing the banner, so clients can distinguish it from an older cached image.
Check `media/README.md` for the capture and font provenance.

Apple's [Messages preview guidance](https://developer.apple.com/documentation/technotes/tn3156-create-rich-previews-for-messages)
recommends an image at least 900px wide, a square icon at least 108px wide, and
metadata reachable in the original response. A client's privacy preferences,
network access, and cached metadata can still affect whether a banner appears.
Testing metadata or Link Presentation is not evidence of sending a real message
or testing every recipient's device.

## Validation

Run `node docs/tests/site-metadata.test.cjs` for canonical URLs, the banner's
actual PNG dimensions, required preview metadata, site identity, and sitemap
links. The existing `node docs/tests/galaxy.test.cjs` entry point runs this
fixture with the other website regressions. Check local links and page anchors,
responsive layouts, and successful public HTML/icon/image responses after
deployment. `robots.txt` and `sitemap.xml` are explicitly website-only CI paths;
unknown text/XML and mixed application changes still require app validation.
