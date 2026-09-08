# Pre-rendered app icon

`AppIcon.icns` and `Assets.car` are `actool`'s output for `../AppIcon.icon`, the Icon
Composer document. They are committed because `actool` only renders a `.icon` on macOS 26
with Xcode 26, and the CI runner may have neither; `make-app.sh` prefers these files and
falls back to rendering the document itself only when they are missing.

Both files ship: `Assets.car` is the real icon (the full 32–2048 ladder plus the layers the
system shapes and lights itself, read via `CFBundleIconName`); the `.icns` is the small
compatibility plate for `CFBundleIconFile`. An `.icns` alone makes Tahoe draw a second
squircle under an already-rounded bitmap.

Refresh after editing `AppIcon.icon` (the document must keep that name — `--app-icon` is
looked up by basename, and any other name silently yields no `.icns`):

```sh
out="$(mktemp -d)"
xcrun actool AppIcon.icon --compile "$out" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$out/icon.plist"
cp "$out/AppIcon.icns" "$out/Assets.car" AppIcon-prebuilt/
```

Finder and the Dock cache icons; if a rebuilt bundle keeps the old one,
`rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Dock`.
