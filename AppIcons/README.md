# Vane icon family

All icon sources and compiled assets live here. Open any `.icon` document in Icon Composer; the V, material layers, and background remain editable. macOS supplies the tile shape and lighting.

Settings → Icon offers **Normal, Dark, Galaxy, Candy, Neon, Fluted Glass, Fluted Glass Dark, Schoolbook, and Luminous**. Normal is the original glass catalogue render (`AppIcon.icon`). Dark is the Dock’s original composition of that same source, with no image override. Galaxy has open blue/ivory spiral arms behind the silver V. The new finishes use a larger folded V and retain Vane’s slate-blue, periwinkle, and ivory palette. Candy has an ivory rim and a blue glass fold; Neon has a bright outline and a blue bloom; Schoolbook uses paper color blocks; Luminous uses a sculpted blue gradient. Fluted Glass places a refracted indigo V beneath fine cylindrical cream-glass ribs, with blue, lilac, and warm peach blooms spreading beyond the logo. Fluted Glass Dark uses the same ribs and colored lighting over deep slate, with a luminous periwinkle V. Both use native blur, refraction, and translucency controls, with reduced blur to retain the silhouette at Dock sizes.

Old saved labels migrate: Default → Dark, Glass → Normal, Navy → Normal. Galaxy and custom images retain their selections.

To regenerate Galaxy’s deterministic editable starfield:

```sh
python3 scripts/generate-galaxy-icon.py
```

To regenerate the six material variants and two outline studies:

```sh
python3 scripts/generate-material-icons.py
```

The light and dark outline studies live in `Experiments/`. They are editable Icon Composer documents, excluded from the production catalogue and Settings picker. `Previews/fluted-comparison.png` compares the previous finishes with the new filled and outline versions, using native macOS renders at enlarged and 80 px Dock sizes. Individual outline renders are also in `Previews/`.

To refresh the single compiled catalogue and compatibility icon on macOS 26 with Xcode 26:

```sh
scripts/compile-app-icons.sh
```

`Prebuilt/Assets.car` contains all eight catalogue images. `Prebuilt/AppIcon.icns` is the compatibility plate for the bundle’s default icon. Commit both after changing a source when their contents change. `make-app.sh` prefers these renders and falls back to compiling the sources when they are missing.

Verify migration and every bundled selection with `scripts/check-app-icons.sh`.
