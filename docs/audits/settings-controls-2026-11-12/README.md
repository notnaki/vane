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
