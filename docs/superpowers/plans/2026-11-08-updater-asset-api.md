# Updater asset downloads

**Goal:** Keep in-app updates working when GitHub's browser download route fails.

**Evidence:** On 2026-11-08 the published `v0.1.0/Vane.zip` browser URL repeatedly
returned HTTP 504. Production `UpdateDownload` returned `invalidResponse`. The
release asset API, with `Accept: application/octet-stream`, returned the complete
29,523,761-byte ZIP with its published SHA-256 and valid notarized Vane signature.

**Design:** Decode both the release asset's API `url` and `browser_download_url`.
Prefer the API and try the other endpoint once after an HTTP/network failure,
without an intermediate failure or retry message. Download with binary content
negotiation, retaining that header across trusted redirects. Both attempts share
one deadline and redirect budget, and partial data is discarded before fallback.
Give the conditional release cache a new namespace so an old browser-only URL
cannot survive a 304 response.
Keep host trust, redirect/deadline/size bounds, cookie isolation, signature checks,
and version/install policy in place.

**Files:** `UpdateChannel.swift` selects and caches API asset URLs;
`UpdateDownload.swift` negotiates binary responses; existing channel, transport,
and updater tests cover the behavior; `docs/RELEASING.md` describes discovery.

## Execution

- [ ] Add regressions for API URL decoding, old conditional cache migration,
  binary downloads through redirects, fallback in both directions, partial data,
  and terminal cancellation/security/size failures. Observe failures before implementation.
- [ ] Implement API asset selection, cache migration and binary request headers.
- [ ] Run channel and hostile transport fixtures, focused updater XCTest tests,
  a build/pure selfcheck, and a live production download with checksum verification.
- [ ] Open a PR, obtain independent review, fix findings, and merge only after
  required CI and the latest main checks complete successfully.

## Review focus

- An old cached browser URL must not survive an unchanged release's 304 response.
- Binary negotiation must survive the API-to-asset redirect.
- API metadata, error bodies, hostile redirects and oversized responses must not
  become installed updates.
- Both Stable and Nightly must select the same API URL form.
- Installation still verifies the pinned Developer ID and refuses downgrades.
