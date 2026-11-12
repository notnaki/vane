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
