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

- `WelcomeIcon.png` is a 256 px copy of the shipped `AppIcons/Previews/Normal.png`,
  used by the onboarding concept approved on November 10, 2026. Regenerate with
  `sips -Z 256 AppIcons/Previews/Normal.png --out Sources/Vane/WelcomeAssets/WelcomeIcon.png`.

- `Search-*.png` are local PNG conversions of official engine favicons (retrieved November 10, 2026):
  `https://www.google.com/favicon.ico`, `https://duckduckgo.com/favicon.ico`,
  `https://www.bing.com/favicon.ico`, `https://brave.com/favicon.ico`,
  `https://kagi.com/favicon.ico`, and `https://www.ecosia.org/favicon.ico`.
  Onboarding never fetches these at runtime.
