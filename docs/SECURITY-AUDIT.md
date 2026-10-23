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

### Update resource limits and application access

Downloads now use a separate cookie-free session, validate every redirect hop, enforce
a total deadline, and stop before writing more than 200 MiB, including responses with
no declared length. Partial files are removed. ZIP extraction accepts only STORE and
DEFLATE, with matching local/central records and CRC verification. Actual expanded bytes
are metered before writing: 1 GiB total, 512 MiB per file, 20,000 filesystem entries
(including implicit directories), 1,024 path bytes, 32 components and a 120-second
cooperative extraction deadline. Traversal, links, special files, encryption, ZIP64,
overlap and filesystem-normalized name collisions are rejected. AppleDouble sidecars
are checked and counted, then discarded; archive ACLs and ownership are never restored.

The browser's two Applications exceptions are read-only. Authenticated XPC now owns
startup recovery, launch-health confirmation and cleanup as well as installation.
Each connection binds mutations to the browser's kernel PID, start time and executable
path; a displaced old process cannot certify the replacement. Rollback retains the
failed stage until the restored app starts, preserving the helper's signature for its
reply; the restored launch removes that stage. Ordinary supervised restart also starts
through XPC so the supervisor can recover outside the browser sandbox.

Signed headless fixtures on macOS 27.0.1 arm64 reproduced Applications writes with the
old entitlements, then verified denial of file/directory creation, modification and
deletion in both `/Applications` and `~/Applications` with the reduced entitlements.
They exercise real pinned XPC authentication, browser-owned health journals, rollback,
deferred cleanup, wrong-identity rejection and displaced-executable rejection. A copy
of the unchanged 20 October notarized release also passed strict signature, Gatekeeper
and stapled-ticket checks after extraction by the new reader. These fixture results
do not replace validation of the final release candidate on supported systems.

Native validation also exposed an older published payload's first-run resource lookup
failure and a fixture that could report success from a database created before a crash.
Current artwork/font lookups now prefer the packaged `Contents/Resources` bundle before
the generated SwiftPM fallback; tests relocate a flat bundle away from its build path.
Upgrade fixtures preserve completed onboarding and require the same browser identity
to remain alive after bootstrap. Production launch-health timing remains unchanged;
the fixture allows slow verification to complete without weakening its success checks.

### Certificate evaluation and native tokens

Each server-trust challenge now receives a fresh system evaluation. The previous
leaf-only session cache could produce stale diagnostics after dates, anchors, chains
or trust policy changed; cached success still delegated to WebKit, so no TLS bypass
was established. Tests use the same leaf with different trust dates and anchors.

GitHub integration tokens now use generic Keychain passwords in a separate service,
scoped to profile and isolated data directory. Existing owned tokens migrate only after
the new item is stored; failed or locked-Keychain operations preserve the original.
Legacy token items are excluded from web-password enumeration, export and direct reads
during migration. Sign-out, profile deletion and erase include native tokens, with
test-instance isolation. Deterministic Keychain fixtures cover failure and race paths.

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
- Repeat helper workspace isolation and the complete signed XPC installation/relaunch
  flow with the final distribution candidate on macOS 26. Local signed fixtures and an
  older unchanged notarized payload are distinct from that candidate-specific check.
- Keep macOS/WebKit patched and preserve App Sandbox, Hardened Runtime, fraudulent
  website warnings, and fail-closed permission checks. Signing/notarization alone
  cannot establish browser security or protect against every engine zero-day.

## Validation

Validation results are recorded in the pull request for this review. Focused suites
cover the changed trust boundaries; required CI and an independent review must pass
before merging. Device authorization, third-party service coverage, and a public
release candidate are separate from local source validation.
