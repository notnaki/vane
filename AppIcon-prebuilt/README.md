# Pre-rendered app icon

`AppIcon.icns` and `Assets.car` are `actool`'s output for the three Icon Composer documents
beside them, `../AppIcon.icon` (Glass, the default) and `../AppIcon-Navy.icon` (the lighter
navy), plus `../AppIcon-Galaxy.icon` (the galaxy website’s blue-violet spiral and silver V).
macOS composes them the same way — the
squircle, the glass over the V, the shadow — and Settings ▸ Icon offers the choice.

They are committed because `actool` only renders a `.icon` on macOS 26 with Xcode 26, and
the CI runner may have neither; `make-app.sh` prefers these files and falls back to
rendering the documents itself only when they are missing.

Both files ship: `Assets.car` is the real icon (the full 32–2048 ladder plus the layers the
system shapes and lights itself, read via `CFBundleIconName`) and it carries **all three** icons,
which is what `AppIcon.swift` looks up by name; the `.icns` is the small compatibility plate
for `CFBundleIconFile`, and it only ever holds the default. An `.icns` alone makes Tahoe draw
a second squircle under an already-rounded bitmap.

Run `python3 scripts/generate-galaxy-icon.py` to regenerate Galaxy’s seeded vector
starfield before compiling. It uses only Python’s standard library. Keep sources unmasked:
macOS supplies the icon shape.

Refresh after editing any document (all must keep their names — `--app-icon` and
`--alternate-app-icon` are looked up by basename, and any other name silently yields no
`.icns` and no second icon):

```sh
out="$(mktemp -d)"
xcrun actool AppIcon.icon AppIcon-Navy.icon AppIcon-Galaxy.icon --compile "$out" \
  --app-icon AppIcon --alternate-app-icon AppIcon-Navy --alternate-app-icon AppIcon-Galaxy --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$out/icon.plist"
assetutil --info "$out/Assets.car" | grep -c AppIcon-Navy   # non-zero, or the alternate went missing
assetutil --info "$out/Assets.car" | grep -c AppIcon-Galaxy # non-zero, or Galaxy went missing
cp "$out/AppIcon.icns" "$out/Assets.car" AppIcon-prebuilt/
```

`icon.plist` adds only `CFBundleIconFile`/`CFBundleIconName`, which `make-app.sh` already
writes: macOS has no alternate-icon API to declare (`setAlternateIconName` is UIKit's), and
Vane switches icons by assigning `NSApp.applicationIconImage`.

Finder and the Dock cache icons; if a rebuilt bundle keeps the old one,
`rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Dock`.
