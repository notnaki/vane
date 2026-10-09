# Releases and distribution

[Documentation index](README.md) · [Project README](../README.md)

A local build, a published archive, and a verified installation are different
milestones. Keep evidence tied to the exact candidate and environment.

## Publish a release

Merging a PR to `main` does not publish a release. Start the release workflow for a
patch bump (or choose `minor` or `major`):

```sh
gh workflow run release.yml
gh workflow run release.yml -f bump=minor
```

Alternatively, push a specific `v*` tag:

```sh
git tag v1.2.3
git push origin v1.2.3
```

The workflow builds `Vane.app`, packages `Vane.dmg` and `Vane.zip`, and publishes them
to a GitHub Release. To produce a Developer ID signed and notarized build, the
repository needs `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`,
`AC_API_KEY_ID`, `AC_API_ISSUER_ID`, and `AC_API_KEY_P8_BASE64` as Actions secrets. The
workflow stops before publishing if any of these five credentials is missing. A tag
containing a hyphen, such as `v1.2.3-rc1`, publishes a prerelease that the in-app
updater does not offer.

### Local signing

Local Developer ID builds can use:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
```

This signs the bundle but does not notarize it. Check the exact release archive with
`check-release-candidate.sh` before treating it as a distribution build.

The optional `GH_OAUTH_CLIENT_SECRET` enables GitHub web-flow sign-in and token renewal
in release builds. Without it, Live Folders uses personal access tokens. Keep release
build products out of PR-readable caches because they can contain the compiled OAuth
secret.

The workflow signs/notarizes/staples the app, then packages ZIP and DMG artifacts; the
DMG is also signed and notarized. The updater consumes `Vane.zip`; the DMG is for manual
installation. Dispatch prepares a version tag and pushes it after packaging succeeds. A
publication retry reuses the run’s tag.

## Updater and distribution validation

Updater failure checks use disposable directories and child processes. The headless
recovery suite kills processes at transaction boundaries, verifies retained contents,
and exercises stale records, retries, rollback and cleanup. The loopback transport suite
probes actual URLSession cancellation and interrupted/truncated HTTP responses; its host
is simulated and never bypasses the production GitHub trust policy.

For real signed/notarized input, pass an unchanged release app to
`scripts/test-update-installer.sh`. Developer ID rejection fixtures can be created with
`SIGN_ID=… scripts/make-updater-rejection-fixtures.sh /path/to/release/Vane.app
/path/to/new-fixture-directory`, then tested with `scripts/test-update-installer.sh
/path/to/release/Vane.app --fixtures /path/to/new-fixture-directory`. These deliberately
unnotarized copies check identity, version, native architecture, signature diagnostics
and actual Gatekeeper rejection. Never use them as a release.

### Signed native recovery

After coordinating a graphical test slot, native recovery can be checked with `SIGN_ID=…
python3 scripts/test-updater-native.py --app /path/to/signed-new/Vane.app --previous
/path/to/unchanged-old/Vane.app --evidence /path/to/evidence`. `SIGN_ID` is required for
pinned Developer ID XPC authentication. Add `--bootstrap-failure` to cover a signed
executable that exits before updater startup, plus stale and malformed journals. The
driver uses unsandboxed staging, Vane’s exact sandbox identity and the authenticated
installer service for isolated restart. It never starts or cleans browser
preferences/profile data itself. Disposable bundles live under Downloads; the fixture
records actual browser environment and exact process identities, including App
Translocation, before cleanup. Isolated restarts use a detached unsandboxed installer
worker and exact child processes; sandboxed LaunchServices callers drop those overrides,
and direct execution from an inherited sandbox fails before main on macOS 27. The
fixture simulates notarization for the local candidate at the transaction boundary;
actual distribution verification remains the separate installer/release-candidate check.
To test the current XPC helper with an unchanged notarized payload, run `SIGN_ID=…
scripts/test-update-installer-xpc.sh /path/to/current/Vane.app
/path/to/notarized/Vane.app`.

### Unchanged release candidate

To verify an *unchanged, notarized* release ZIP on a graphical test machine:

```sh
scripts/check-release-candidate.sh Vane.zip /path/to/empty-evidence-directory
```

That script checks the archive and bundle contents, signature, stapled ticket,
Gatekeeper assessment, and WebKit smoke test, and saves evidence. A clean Mac
installation and upgrade still need to be exercised separately.

The [updater recovery audit](UPDATER-RECOVERY-AUDIT.md) records confirmed fixes, signed
native recovery, unchanged published-release acceptance, and simulated boundaries. Local
Developer ID recovery fixtures simulate candidate notarization; they do not establish
approval of the changed build.

## Release checklist

- Run the [release-configuration and smoke checks](DEVELOPMENT.md#release-and-graphical-smoke-checks) appropriate to the candidate.
- Confirm required PR checks and review passed for the source being released.
- Validate the unchanged notarized archive with `scripts/check-release-candidate.sh`.
- Exercise a clean-Mac install and upgrade/rollback separately. Retain the exact archive, revision, macOS version, signature, and results.
- Review [compatibility evidence](REAL-SITE-COMPATIBILITY.md) and [remaining readiness work](BROWSER-READINESS-TODO.md); do not convert skipped/account/device checks into passes.
- Confirm all task-owned browser/helper processes exited and remove only owned test resources.

Passkeys additionally need Apple’s managed browser entitlement approval, matching
provisioning, and registration/sign-in validation. A Developer ID certificate or
notarization alone does not enable them.
