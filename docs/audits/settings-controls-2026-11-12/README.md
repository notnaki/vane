# Settings controls visual check

Captured on macOS 27.0.1 with Xcode 27.0 / SDK 27.0 from the settings-controls
implementation in `ba41f9c1`. These are native SwiftUI `NSHostingView` renders of
pane content, not full application-window captures. They use the isolated XCTest
preferences and contain no personal browsing data or accounts.

- `animations-dark.png`: stepped speed controls, values, resets, and shared search.
- `shortcuts-dark.png`: shared full-width search above the list and guidance.

Both are 632 × 650 points at 2× scale. Light-mode, 350-point animation-height,
and additional settings-pane renders were also inspected locally. Reproduce with:

```sh
VANE_ANIMATION_SETTINGS_SNAPSHOTS=/tmp/settings-animations \
VANE_SETTINGS_SNAPSHOTS=/tmp/settings-panes \
python3 scripts/run-native-tests.py --jobs 1 \
  --filter 'UIAnimationSettingsTests|SettingsPresentationTests|UpdateChannelSettingsTests'
```

The focused run passed 13 tests and the native retirement/cleanup check. The
step-mapping regression verifies all eight speed choices against saved animation
durations. A preliminary attempt to exercise the slider through the XCTest
host's accessibility tree could not expose any SwiftUI children; it was replaced
with that direct boundary test. These renders and checks do not establish a
VoiceOver interaction pass.

## CI readiness follow-up

The first [PR checks run](https://github.com/notnaki/vane/actions/runs/43195843012)
failed native shard 4 on late shadow-field discovery and snapshot pointer
intrusion. The final `checks` failure was the aggregate consequence.

Three unchanged local reproductions and three diagnostic runs passed; those
passes were not treated as resolving the hosted assertions. Diagnostics showed
the timer-driven password fixture used a hidden WebKit document and unordered
window. It now admits its exact active owner and visible document before each
mutation, preserving the five-second discovery deadlines and fill assertions.

The snapshot admission failure reported native occlusion despite key ownership.
The helper now re-presents an already-key occluded owner, restores offscreen
placement, and requires native visibility plus full on-screen placement before
capture. System window-opening animations are disabled for this snapshot shell;
SwiftUI animations remain enabled.

Broader local preflight also exposed the covering-window regression's dependence
on AppKit reporting same-app overlap. WindowServer diagnostics showed full opaque
coverage while AppKit continued reporting visible, including with a full-screen
cover. Chromium documents a related [native occlusion limitation](https://raw.githubusercontent.com/chromium/chromium/main/components/remote_cocoa/app_shim/window_occlusion_checker_mac.h).
The fixture now moves the still-key ordered owner fully offscreen, observes its
actual native occlusion before recovery, and asserts native visibility and
on-screen placement afterward. No occlusion state is mocked, and the original
ten-second outcome deadline remains. Same-app covering detection is no longer
the stimulus for that test.

Final local preflight on macOS 27.0.1: three sequential runs of
`PasswordShadowAutofillTests|SidebarSnapshotReadinessTests`, each with 35 passing
tests and verified cleanup. Independent review found no actionable issues.
Original hosted validation used macOS 26.7.2; full hosted CI must validate the
repair before merging. Every local attempt, including failed diagnostic and
intermediate preflights, remains in `/tmp/vane-665-*.log`; the final three logs are
`/tmp/vane-665-final-preflight-{1,2,3}.log`.

## Activation-policy follow-up

The [next hosted run](https://github.com/notnaki/vane/actions/runs/43203073710)
failed shard 3 in `EmptyPinnedSectionGeometryTests` before its geometry body,
with `policyChanged` during loop acquisition. The fixture requested accessory
policy outside the helper and then acquired a default-policy lease, allowing an
asynchronous transition to invalidate the policy snapshot. It now passes
`activationPolicy: .accessory` to the existing bounded admission path. Policy
restoration, geometry assertions, readiness deadlines, and cleanup are unchanged.

One unchanged local baseline passed and was retained without treating it as a
resolution. After the repair, three sequential preflights each passed eight tests:
`EmptyPinnedSectionGeometryTests`, `NativeFixtureActivationPolicyAdmissionTests`,
and the transient-return case in `NativeFixturePolicySettlementTests`. All three
cleanup runs passed, and independent review found no actionable issues. Logs are
`/tmp/vane-665-policy-baseline.log` and `/tmp/vane-665-policy-preflight-{1,2,3}.log`;
the hosted failure is retained in `/tmp/vane-665-shard3-failure.log`.

## Visible-document readmission follow-up

On `ad1c833f`, the hosted late-shadow fixture failed its pre-action admission,
before the first DOM mutation. Terminal diagnostics showed a visible document and
key window but omitted other native readiness flags. The exact hosted trigger is
not proven. The cancelled sibling shards and aggregate gate are consequences of
that shard-4 failure.

Two controlled regressions now exercise withdrawn presentation and a one-point
offscreen displacement. Both failed before the repair; the offscreen case
reproduced the hosted visible/key/active/document-visible signature and secondary
`InvalidTransition` report. Admission now restores only its still-attached owned
window's placement/presentation within the original five-second budget. It retains
the complete native predicate and rechecks native readiness after awaiting the
WebKit visibility result. Diagnostics preserve the last unready native sample,
including geometry, identity, process state, and screen bounds.

After repair, the original discovery, stale-target, and current-fill assertions
pass in both controls. Three sequential broader preflights each passed 38 tests
and cleanup (`PasswordShadowAutofillTests|SidebarSnapshotReadinessTests|EmptyPinnedSectionGeometryTests`).
Independent review found no actionable issues. Evidence remains in
`/tmp/vane-665-ad1-shard4-failure.log`, `/tmp/vane-665-readmission-red.log`,
`/tmp/vane-665-readmission-green.log`, and
`/tmp/vane-665-readmission-preflight-{1,2,3}.log`.

## Hidden-control visibility-boundary follow-up

The [run on `dea8d959`](https://github.com/notnaki/vane/actions/runs/43210954780)
passed the original late-shadow discovery and offscreen readmission cases, but
failed the new hide/show control's document-visibility admission. Its last native
unready sample showed the initial hidden window, while terminal native and WebKit
visibility were ready. The sibling cancellation and aggregate failure followed
that shard-3 failure.

The control previously hid the owner before confirming its document-visible
baseline, then requested restoration without observing WebKit's hidden boundary.
[WebKit coalesces activity-state updates](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/WebPageProxyCocoa.mm#L1030),
so native ordering alone does not establish that fault prerequisite. Withdrawal
controls now first admit the visible document; the hide/show control additionally
observes the actual hidden document before starting recovery. These are bounded
fault-setup prerequisites, not added time for recovery or discovery outcomes. The
original five-second recovery and discovery budgets and all assertions remain.
Diagnostics now retain each last JavaScript visibility sample and its post-await
loop/native readiness.

The focused four-case run and three sequential broader 38-test preflights passed,
including cleanup. Independent review found no actionable issues. Evidence remains
in `/tmp/vane-665-dea-shard3-failure.log`,
`/tmp/vane-665-visibility-boundaries-focused.log`, and
`/tmp/vane-665-visibility-boundaries-preflight-{1,2,3}.log`.
