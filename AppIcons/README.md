# Vane icon family

All icon sources and compiled assets live here. Open any `.icon` document in Icon Composer; the V, material layers, and background remain editable. macOS supplies the tile shape and lighting.

Settings → Icon offers **Normal, Dark, Galaxy, Candy, Neon, Fluted Glass, Fluted Glass Dark, Schoolbook, and Luminous**. Normal is the original glass catalogue render (`AppIcon.icon`). Dark is the Dock’s original composition of that same source, with no image override. Galaxy has open blue/ivory spiral arms behind the silver V. The new finishes use a larger folded V and retain Vane’s slate-blue, periwinkle, and ivory palette. Candy has an ivory rim and a blue glass fold; Neon has a bright outline and a blue bloom; Schoolbook uses paper color blocks; Luminous uses a sculpted blue gradient. Fluted Glass places a refracted indigo V outline beneath wide cylindrical glass ribs, with soft silver-blue lighting spreading beyond the logo. Fluted Glass Dark uses the same ribs and lighting over deep slate, with a luminous blue outline. Both use native blur, refraction, and translucency controls, with reduced blur to retain the silhouette at Dock sizes.

Old saved labels migrate: Default → Dark, Glass → Normal, Navy → Normal. Galaxy and custom images retain their selections.

To regenerate Galaxy’s deterministic editable starfield:

```sh
python3 scripts/generate-galaxy-icon.py
```

To regenerate the six material variants and ten palette/outline studies:

```sh
python3 scripts/generate-material-icons.py
```

The approved production finish is the silver-blue outline in both light and dark. The ten alternative studies in `Experiments/` are editable Icon Composer documents, excluded from the production catalogue and Settings picker: silver-blue filled logos, plus neutral silver-white and ivory/champagne with filled and outline logos. `Previews/fluted-palettes-filled.png` and `Previews/fluted-palettes-outline.png` preserve the three-palette comparison, including native 80 px renders. `Previews/fluted-comparison.png` preserves the earlier comparison of filled and outline proposals. Individual renders are also in `Previews/`; `Fluted Glass.png`, `Fluted Glass Dark.png`, and `family.png` show the selected production finish.

To refresh the single compiled catalogue and compatibility icon on macOS 26 with Xcode 26:

```sh
scripts/compile-app-icons.sh
```

`Prebuilt/Assets.car` contains all eight catalogue images. `Prebuilt/AppIcon.icns` is the compatibility plate for the bundle’s default icon. Commit both after changing a source when their contents change. `make-app.sh` prefers these renders and falls back to compiling the sources when they are missing.

Verify migration and every bundled selection with `scripts/check-app-icons.sh`.

### Blocky Vane studies

`Experiments/AppIcon-BlockyPixel.icon`, `AppIcon-BlockyBlock.icon`, and
`AppIcon-BlockyScatter.icon` adapt Vane's curved V to the stepped square-grid
style of the Vesta terminal's pixel/glitch icon studies. Pixel uses a 40 px
grid; Block and Scatter use 64 px blocks. Scatter displaces two chips and adds
faint satellite blocks. The ivory mark, slate-blue tile, and native glass
finish retain the Vane palette. These are editable experiments outside the
production catalogue and Settings picker.

Regenerate the SVG silhouettes and Icon Composer documents with:

```sh
python3 scripts/generate-blocky-icons.py
```

`Previews/Blocky Pixel.png`, `Blocky Block.png`, and `Blocky Scatter.png` are
native 1024 px macOS renders. `Previews/blocky-comparison.png` shows all three,
with 80 px previews below each to check the Dock silhouette. Refresh a native
render with the Icon Composer CLI bundled in Xcode:

```sh
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" AppIcons/Experiments/AppIcon-BlockyPixel.icon --export-image \
  --output-file "AppIcons/Previews/Blocky Pixel.png" --platform macOS \
  --rendition Default --width 1024 --height 1024 --scale 1
```
