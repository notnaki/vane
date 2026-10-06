# Welcome artwork

- `VaneLogo.pdf` is a vector export of the exact filled V in
  `AppIcons/AppIcon.icon/Assets/vane-v.svg`. Regenerate it with
  `python3 scripts/build-welcome-logo.py`. The path and ivory fill are preserved;
  SwiftUI tints it to match the welcome's appearance.
- `Search.png` and `Spaces.png` are real Vane screenshots captured on 2026-10-06
  in a disposable `VANE_DATA_DIR` profile. They contain sample browsing data,
  with no personal browsing data. SwiftUI frames the relevant controls at runtime.
- The search capture uses Wikipedia’s Architecture article as a sample history
  and archived-tab title. The capture contains Vane’s own controls and background.
