# Releases and distribution

[Documentation index](README.md) · [Project README](../README.md)

A local build, a published archive, and a verified installation are different
milestones. Keep evidence tied to the exact candidate and environment.

## Release cadence

Vane is maintained by one person. Releases follow readiness and available time;
there is no weekly stable deadline or promise of a new build every night.

| Event | What happens |
| --- | --- |
| A PR merges to `main` | `checks.yml` runs. The merge itself does not publish a release or change a version number. |
| Daily at **02:23 UTC** (**05:23 Türkiye time**, UTC+3) | GitHub schedules a Nightly eligibility check. This is a publication opportunity, not a guaranteed release time; scheduling, queued runs, builds, and notarization can delay it. |
| The scheduled revision has passing checks and has not been published as a nightly | The workflow builds and publishes a signed, notarized Nightly prerelease. |
| No new nightly revision, or the exact revision's latest checks are missing, pending, or unsuccessful | The Nightly run skips publication. There is no manual daily chore and no automatic catch-up when checks later pass; the next scheduled opportunity or a manual Nightly dispatch checks again. |
| A change is ready for Stable | The maintainer deliberately dispatches a Stable release, choosing `patch`, `minor`, or `major`. There is no calendar-based stable release. |
| An urgent fix is ready | Dispatch a Stable patch as soon as it is validated; there is no need to wait for a Nightly. |
| A specific `v*` tag is pushed | The workflow publishes that exact version without calculating a bump, except that the reserved `-nightly.*` namespace is refused. |

Nightly means the early-update channel, not a daily output quota. Long gaps are
normal when there are no changes or the maintainer is away. A successful workflow
can mean “nothing eligible to publish”; check the **Select release channel** log
before assuming a new release exists. All release runs share one queue and do not
cancel each other.

## Version numbers and controls

The public version is `MAJOR.MINOR.PATCH`, for example `0.0.39`. Use the following
bump policy when deliberately cutting a Stable release; commit messages and PR
labels do not choose a bump automatically.

This policy applies to future releases. Historically, Stable releases through
`0.0.39` used the third number as a release counter for both fixes and substantial
new features. Those older numbers do not distinguish fixes from feature
milestones. Keep the existing tags and releases; adopting this convention does
not renumber history or require an immediate release.

| Number or control | Meaning / when to change it |
| --- | --- |
| `PATCH`, the third number | Routine fixes, security fixes, polish, and small compatible improvements. This is the default release bump. `0.0.39` → `0.0.40`. |
| `MINOR`, the second number | A meaningful feature milestone or a substantial group of compatible improvements. Resets patch to zero: `0.0.39` → `0.1.0`. |
| `MAJOR`, the first number | A deliberately declared major milestone or incompatible change. Resets minor and patch to zero: `0.8.4` → `1.0.0`. Moving to `1.0.0` is a separate readiness decision, never a date or commit-count threshold. |
| Leading `0` | Vane is still before its `1.0` milestone. No number of patches automatically rolls it to the next minor or major; `0.0.99` → `0.0.100` is valid. |
| `channel=stable` / `channel=nightly` | Selects what the release workflow publishes. Defaults to Stable on manual dispatch; scheduled runs select Nightly. This does not change anyone's in-app channel preference. |
| `bump=patch` / `minor` / `major` | Controls the next Stable version on manual dispatch. Defaults to patch and is ignored for Nightly or a pushed tag. Calculation starts from the numerically highest exact `vMAJOR.MINOR.PATCH` tag, including a tag without a published release; prerelease tags do not count. With no stable tags, patch starts at `v0.0.1`. |
| `v` in `v0.0.40` | Git tag prefix. The release build strips it before stamping the app version. |
| `-nightly.YYYYMMDD.N` | Marks a Nightly prerelease. The core is the next patch after the highest stable tag; the date is the workflow run's original UTC creation date, not its eventual publication date. `N` is the next available numeric counter for that core and date, normally starting at 1. |
| Workflow run ID / attempt | GitHub execution identifiers, not the current public nightly counter. The run ID is stored in the annotated tag as `vane-release-run:ID` so a publication retry can reuse its tag and source. Legacy nightlies used the run ID as their last number. |
| `VANE_VERSION` → `CFBundleShortVersionString` | The app's public version and the updater's ordering input. CI sets it to the selected tag without `v`. Local builds default to the nearest reachable tag (`git describe --tags --abbrev=0`), or `0.1.0` if no usable tag exists; that fallback is not a release declaration. |
| `VANE_BUILD` → `CFBundleVersion` | Build metadata, defaulting to the count of commits reachable from `HEAD`. It is not a release counter and does not make an equal public version upgradeable. CI uses this default. |
| `schedule.cron` in [release.yml](../.github/workflows/release.yml) | Controls when automated Nightly eligibility is checked. It does not control Stable publication or in-app update polling. |

Nightly counters reset for each UTC date and version core. An existing legacy
run-ID suffix on the same core/date is counted too, so the next counter may be
large. A retry after its tag has been pushed reuses that tag and verifies the
source commit; a failure before the push reserves no remote version, so a later
retry can recalculate from the tags then present. Existing remote tags are never
overwritten.

For example, after stable `v0.0.39`, the first eligible run on 7 November 2026 can
produce `v0.0.40-nightly.20261107.1`. A second manual Nightly with a new checked
revision that day uses `.2`; an unchanged revision produces nothing. A new date
starts at `.1`. A deliberate Stable patch publishes `v0.0.40`, which outranks all
`0.0.40-nightly.…` versions; subsequent nightlies use `0.0.41-nightly.…`. Choosing
minor instead publishes `v0.1.0` and subsequent nightlies use `0.1.1-nightly.…`.

## Publish a release

Merging a PR to `main` does not publish a stable release. Start the release workflow
for a patch bump (or choose `minor` or `major`):

```sh
gh workflow run release.yml --ref main -f channel=stable -f bump=patch
gh workflow run release.yml --ref main -f channel=stable -f bump=minor
gh workflow run release.yml --ref main -f channel=stable -f bump=major
```

Alternatively, push a specific `v*` tag:

```sh
git tag v1.2.3
git push origin v1.2.3
```

Use `--ref main` for normal releases. Stable dispatch and explicit tag pushes do
not have the automated Nightly checked-main gate: the maintainer must confirm
the intended revision's validation and readiness before starting them.

The workflow builds `Vane.app`, packages `Vane.dmg` and `Vane.zip`, and publishes them
to a GitHub Release. To produce a Developer ID signed and notarized build, the
repository needs `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`,
`AC_API_KEY_ID`, `AC_API_ISSUER_ID`, and `AC_API_KEY_P8_BASE64` as Actions secrets. The
workflow stops before publishing if any of these five credentials is missing. A tag
containing a hyphen, such as `v1.2.3-rc1`, publishes a prerelease. Release candidates
and betas are not offered by either in-app update channel.

### Nightly channel

**Settings → General → Update channel** offers **Stable** (the default) and
**Nightly**. Nightly opts into automated early builds as well as newer stable
releases. Both channels use the same app, profile data, signed installer, and
version/downgrade checks. Changing the channel clears any pending offer and
invalidates outstanding checks; an installation already in progress finishes.
Automatic checks remain controlled by their existing toggle, and **Check for
Updates…** always uses the selected channel. Selecting Stable again waits for a
stable release newer than the running and installed versions; it does not roll
back the app or its data.

At each scheduled or manual Nightly opportunity, publication is skipped unless
the exact `main` revision has a successful,
completed latest `checks.yml` push run and has not already been published as a
nightly. A read-only Ubuntu job performs eligibility checks before the macOS job
receives signing credentials. The build checks out that exact revision and reuses
the stable pipeline's signing, notarization, stapling, smoke tests, ZIP and DMG.
No release build products enter PR-readable caches.

To request the same checked-main path manually:

```sh
gh workflow run release.yml --ref main -f channel=nightly
```

The [numbering rules above](#version-numbers-and-controls) define Nightly tags and
retry behavior. Tags push only after packaging succeeds, and nightlies are GitHub
prereleases with `latest=false`, leaving the stable download link unchanged. The
`-nightly.*` tag namespace is reserved for this workflow; direct tag-push releases
are refused.

New installations default to Stable even when the app was downloaded from a nightly
release; select Nightly explicitly to continue receiving early builds. Stable and
Nightly store conditional-request headers and cached offers separately.

Focused fixtures: `python3 scripts/test-update-channel.py`,
`python3 scripts/test-prepare-nightly.py`, `python3 scripts/test-release-workflow.py`,
and `swift test --filter UpdaterChannelTests`.

### When a published release reaches the app

Publication and update discovery have separate schedules. Stable queries GitHub's
`releases/latest`; Nightly queries the latest 100 releases and selects the highest
eligible Stable or Nightly version. Neither channel accepts draft, beta, or RC
releases. The updater compares public version numbers numerically, including
Nightly date/counter components; a newer publication timestamp or build number
alone does not win. An update must be newer than both the running app and any
existing installation at the destination.

With automatic checks enabled, Vane checks about five seconds after launch, when
returning to the app if at least five minutes have elapsed since the last check,
and on its minute timer once at least 30 minutes have elapsed. After a network or
rate-limit error, automatic activation/timer checks back off to one hour. These
intervals live in `Release.activationFloor`, `Release.period`, and
`Release.backoffPeriod` in [Updater.swift](../Sources/Vane/Updater.swift); launch
delay and timer tick are in `Updater.begin()`. **Check for Updates…** bypasses the
automatic toggle and timing floors. Active downloads/installations and updates
awaiting relaunch keep their existing transaction rather than starting another.

### Publication order and failures

The pipeline checks credentials, selects a local version tag, builds and signs the
app, runs the packaged pure smoke check, notarizes/staples the app, and packages
the ZIP and signed/notarized/stapled DMG. Only then does it push a prepared tag and
create the GitHub Release. A manually pushed tag already exists before the build;
it does not prove packaging or publication succeeded. The updater needs the
published release and its `Vane.zip` asset, not just a tag or a green prepare job.

If building, signing, notarization, or packaging fails, a dispatch does not push
its prepared tag. If publication fails after the tag push, rerun that workflow
run to retry its reserved version. An existing release's assets are replaced on
retry. A new manual dispatch is a new run and can allocate another version.

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
probes the production bounded transport, cancellation, hostile redirects, slow responses,
oversized bodies and interrupted/truncated HTTP responses; its host
is simulated and never bypasses the production GitHub trust policy.

For real signed/notarized input, pass an unchanged release app to
`scripts/test-update-installer.sh`. Developer ID rejection fixtures can be created with
`SIGN_ID=… scripts/make-updater-rejection-fixtures.sh /path/to/release/Vane.app
/path/to/new-fixture-directory`, then tested with `scripts/test-update-installer.sh
/path/to/release/Vane.app --fixtures /path/to/new-fixture-directory`. These deliberately
unnotarized copies check identity, version, native architecture, signature diagnostics
and actual Gatekeeper rejection. Never use them as a release.

The installer first freezes the incoming bundle in a unique workspace under Darwin's
per-user temporary directory, validates that copy, assesses Gatekeeper, and removes its
quarantine there. It then copies the prepared payload into the atomic replacement
transaction and verifies that final copy. Quarantine removal does not run in an
Applications sibling. The workspace is selected by
the helper, independently of inherited `TMPDIR`, source, and destination paths.

The installer script also runs a standalone preparation regression: real filesystem and
quarantine operations simulate a client changing an Applications stage at the preparation
boundary, source changes, rejected verification, preparation/publication failure cleanup,
and symbolic-link source rejection. Its content-verification callback is simulated; it
does not prove Developer ID trust. A separate native isolation probe on 2026-10-23 used
macOS 27.0.1 (26A434), arm64, ad-hoc signing with Hardened Runtime, the
`Vane.entitlements` from revision `24bd504`, and unique identifier
`io.github.notnaki.vane.workspace-probe.007480f1013e419483a045c431817bba`. An unsandboxed
driver created a canary in a `Vane-prepared-*` directory under Darwin's per-user temp root.
The sandboxed probe could create, read, and delete its own temporary file, but opening the
helper-temp canary for either reading or writing returned `EPERM` (errno 1). The canary
remained unchanged. The probe recorded PID 83859, kernel start time 1792732665789980
microseconds, and its exact temporary executable path; it exited with status 0 and the
driver removed the temporary app and canary. Full local signature/entitlement and process
evidence is `/tmp/vane-workspace-probe-007480f1013e419483a045c431817bba.json`.

The standalone [probe source](../Tests/UpdatePreparation/SandboxProbe.swift) is retained
for manual reruns in a newly identified temporary bundle, using
`codesign --force --options runtime --entitlements Vane.entitlements --sign - /path/to/Probe.app`
and direct executable invocation with the owned canary path. Such runs can leave an
OS-managed empty container scaffold for their unique probe identity; this run left
`~/Library/Containers/io.github.notnaki.vane.workspace-probe.007480f1013e419483a045c431817bba/`.
Its only probe data file was deleted. Never reuse Vane's identity, register the probe as a
browser, or recursively delete protected container metadata. This probe is opt-in rather
than part of ordinary installer tests.

This establishes the workspace denial on that OS with those entitlements and no
extra user-granted file access. macOS 26 and
an unchanged notarized release candidate still require their separate checks. The change
is defense in depth for a compromised browser main process, not evidence of a remotely
demonstrated sandbox escape.

The browser now has read-only Applications access. Installation, recovery and health
cleanup run in the authenticated helper, using the browser's kernel process identity.
Run `bash scripts/test-update-launch-ownership.sh` for identity/race checks and
`SIGN_ID=… bash scripts/test-update-launch-xpc.sh` for signed headless tests. The latter
creates unique canaries in both Applications folders, verifies sandbox write denial,
and exercises authenticated health, rollback, deferred cleanup and wrong/displaced
caller rejection. It records and cleans only its disposable client/helper processes.

Run `python3 scripts/test-updater-archive.py` for the production ZIP reader and
`python3 scripts/test-updater-transport.py` for its downloader. Limits are 200 MiB
compressed, 1 GiB expanded, 512 MiB per file, 20,000 filesystem entries (including
implicit directories), 1,024 path bytes, 32 components, and a 120-second cooperative
extraction deadline. Downloads have an independent total timeout, byte checks before
writes, and trusted redirects. ZIP64, non-STORE/DEFLATE codecs, encryption, links,
special files, traversal and ambiguous names are refused. The fixtures include real
ditto packaging and strict signature verification; validate the unchanged distribution
candidate as well. An unchanged notarized 20 October release passed extraction,
strict signature, Gatekeeper and stapled-ticket checks locally on 23 October.

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
The upgrade fixture preserves completed onboarding and requires the restored browser
to remain alive after database creation. The published v0.0.34 app can crash in its
fresh-profile welcome screen because its generated resource accessor looks beside
the app rather than under `Contents/Resources`; this older-payload issue must not be
mistaken for a successful first installation. Fresh-profile startup remains part of
the unchanged candidate check, separately from upgrade/rollback validation.
Current artwork and font lookups use `AppResources`, preferring the packaged resource
directory before invoking the generated SwiftPM fallback. Relocation/flat-bundle tests
cover this fix independently of the installed build directory.
To test the current XPC helper with an unchanged notarized payload, run `SIGN_ID=…
scripts/test-update-installer-xpc.sh /path/to/current/Vane.app
/path/to/notarized/Vane.app`.

### Unchanged release candidate

To verify an *unchanged, notarized* release ZIP on a graphical test machine:

```sh
scripts/check-release-candidate.sh Vane.zip /path/to/empty-evidence-directory
```

That script extracts with the production update reader, then checks bundle contents, signature, stapled ticket,
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
