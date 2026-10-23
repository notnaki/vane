# Security review — 23 October 2026

This review examines Vane's own trust boundaries. It is not a penetration-test
certification or a guarantee against undisclosed WebKit or macOS vulnerabilities.
Vane uses the system WebKit engine; users must install Apple's macOS and applicable
Safari security updates. Check [Apple's security releases](https://support.apple.com/en-us/100100)
at release time rather than relying on a hardcoded version recommendation.

## Threats examined

- Hostile websites and embedded frames reaching native permissions, password
  access, Reader, or external applications.
- Untrusted backups importing executable scripts or remembered security consent.
- Modified extension folders, reviewed code, permission expansion, and saved articles.
- Compromised update input, signature validation, quarantine handling, and a
  compromised sandboxed browser process attempting to influence its installer.

## Changes from this review

### External applications

WebKit's initiating frame supplies the requesting origin. A child frame previously
inherited the top-level site's name and host-only launch permission. Saved grants
now require the exact scheme, host, port, and profile. Private answers are memory-only
and belong to one private tab. Legacy host-only grants require fresh consent.
The prompt shows the full requesting origin. Navigation, release, or closing a tab
dismisses its request, and stale button callbacks cannot approve another document.

Real WebKit regressions reproduced the incorrect embedded-frame attribution and
the prompt surviving navigation before the fixes. Store tests cover profile,
scheme, port, private-tab isolation, revocation, and legacy grants.

### Reader

Page-controlled JavaScript could replace `JSON.stringify` and DOM prototypes used
by extraction, forging the data passed to Vane's native parser. Extraction,
availability checks, and the guarded document replacement now use a separate
`WKContentWorld`; the document token is hidden from the page's JavaScript world.
Output budgets limit text, nodes, nesting, and serialized bytes before native
recursive decoding and rendering. Oversized or deeply nested articles are rejected.

Fixtures reproduced forged results from page serializer/prototype overrides and
acceptance of oversized/deep articles before these changes. This establishes a
trust-boundary and resource-bounds issue; no native code execution was demonstrated.

### Backup consent

An incoming backup retains Boost source code and styles, but scripts start disabled
until explicitly enabled again. Restored security decisions require fresh consent:
certificate exceptions, device/location decisions, external-app grants, HTTP
downgrade exceptions, and extension permission approval are discarded. This applies
to every restored profile, including profiles not currently open. Exact interrupted
restore rollback preserves the original library's decisions.

The attack requires a user to restore an attacker-supplied backup. Merely downloading
a backup does not execute its scripts. Ordinary browser preferences still restore;
the archive remains unencrypted and should be treated as sensitive.

### Update preparation

The installer verifies and prepares a frozen copy in a helper-selected Darwin
temporary workspace before copying it into the application replacement transaction.
It never removes quarantine from an Applications sibling writable by the browser.
The final published copy still undergoes signature verification. A deterministic
filesystem fixture exercises adversarial source/stage mutation and failure cleanup.
A separate ad-hoc signed Hardened Runtime probe using Vane's current entitlements
on macOS 27.0.1 arm64 was denied read/write access to a canary under the helper's
Darwin temp root, while its own sandbox temp operations succeeded. This validates
that path boundary on the tested system, not the complete distribution update flow.
See [distribution validation](RELEASING.md#updater-and-distribution-validation)
for the distinction between this fixture and signed sandbox/XPC validation.

## Existing protections examined

Source inspection found exact-origin and profile checks, isolated password message
handlers, random document/field targets, trusted HTTPS requirements for autofill,
and revalidation after synchronous page input handlers. Extension code copying
rejects symlinks and special files and freezes reviewed code; native messaging is
unsupported. Saved Reader markup is escaped/allowlisted with JavaScript disabled
and confined local-file read access. Updater checks include pinned signing identity,
version, architecture, Gatekeeper assessment, and authenticated XPC callers.

These are source-review observations, not new compatibility or exploit-resistance
certifications. Previously recorded tests remain scoped to their stated revisions.

## Remaining work and release gates

- Verify the unchanged signed/notarized candidate, minimum supported macOS, clean
  installation and upgrade/rollback using the [release checklist](RELEASING.md#release-checklist).
- Repeat helper workspace isolation and the complete XPC installation/relaunch flow
  under distribution signing and on macOS 26. The browser retains Applications write exceptions
  for startup recovery/health mutations; moving those into authenticated XPC would
  reduce the damage possible after a browser main-process compromise.
- Bound updater bytes while downloading and expanded ZIP bytes/entries during
  extraction. Current limits reject oversized compressed input after download;
  compromised release hosting can consume disk before signature rejection.
- Replace or bound the leaf-only certificate-evaluation cache. Cached success still
  delegates to WebKit, so this review did not establish a TLS validation bypass;
  diagnostics can become stale after certificate validity or trust-store changes.
- Keep integration tokens separate from autofill-eligible web passwords. No exploit
  at the GitHub API origin was established in this review.
- Keep macOS/WebKit patched and preserve App Sandbox, Hardened Runtime, fraudulent
  website warnings, and fail-closed permission checks. Signing/notarization alone
  cannot establish browser security or protect against every engine zero-day.

## Validation

Validation results are recorded in the pull request for this review. Focused suites
cover the changed trust boundaries; required CI and an independent review must pass
before merging. Device authorization, third-party service coverage, and a public
release candidate are separate from local source validation.
