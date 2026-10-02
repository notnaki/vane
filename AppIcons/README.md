# Vane icon family

All icon sources and compiled assets live here. Open any `.icon` document in Icon Composer; the V, material layers, and background remain editable. macOS supplies the tile shape and lighting.

Settings → Icon offers **Normal, Dark, Galaxy, Candy, Neon, Fluted Glass, Schoolbook, and Luminous**. Normal is the original glass catalogue render (`AppIcon.icon`). Dark is the Dock’s original composition of that same source, with no image override. Galaxy has open blue/ivory spiral arms behind the silver V. The new finishes use rounded, overlapping V ribbons and retain Vane’s slate-blue, periwinkle, and ivory palette.

Old saved labels migrate: Default → Dark, Glass → Normal, Navy → Normal. Galaxy and custom images retain their selections.

To regenerate Galaxy’s deterministic editable starfield:

```sh
python3 scripts/generate-galaxy-icon.py
```

To regenerate the five material variants:

```sh
python3 scripts/generate-material-icons.py
```

To refresh the single compiled catalogue and compatibility icon on macOS 26 with Xcode 26:

```sh
scripts/compile-app-icons.sh
```

`Prebuilt/Assets.car` contains all seven catalogue images. `Prebuilt/AppIcon.icns` is the compatibility plate for the bundle’s default icon. Commit both after changing a source. `make-app.sh` prefers these renders and falls back to compiling the sources when they are missing.

Verify migration and every bundled selection with `scripts/check-app-icons.sh`.
