# Vane icon family

All icon sources and compiled assets live here. Open any `.icon` document in Icon Composer; the V, material layers, and background remain editable. macOS supplies the tile shape and lighting.

Settings → Icon offers **Normal, Dark, Galaxy, Candy, Neon, Fluted Glass, Fluted Glass Dark, Schoolbook, and Luminous**. Normal is the original glass catalogue render (`AppIcon.icon`). Dark uses the approved black rendition of that same source, frozen in `Static.xcassets/AppIcon-Dark.imageset/Dark.png`. Both are explicit images, so Settings, the running Dock tile, and the persisted Finder icon stay on the same finish. Galaxy has open blue/ivory spiral arms behind the silver V. The new finishes use a larger folded V and retain Vane’s slate-blue, periwinkle, and ivory palette. Candy has an ivory rim and a blue glass fold; Neon has a bright outline and a blue bloom; Schoolbook uses paper color blocks; Luminous uses a sculpted blue gradient. Fluted Glass places a refracted indigo V outline beneath wide cylindrical glass ribs, with soft silver-blue lighting spreading beyond the logo. Fluted Glass Dark uses the same ribs and lighting over deep slate, with a luminous blue outline. Both use native blur, refraction, and translucency controls, with reduced blur to retain the silhouette at Dock sizes.

After a successful Finder stamp, Vane refreshes the Dock’s canonical icon cache so quitting immediately retains the new choice. On macOS Tahoe this re-publishes the existing system icon appearance configuration without changing it. The refresh is feature-detected and best effort; a future system without that private publisher still retains the on-disk image.

Old saved labels migrate: Default → Dark, Glass → Normal, Navy → Normal. Galaxy retains its selection. Previously saved custom-image selections return to Dark.

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

`Prebuilt/Assets.car` contains all nine catalogue images, including the frozen black rendition. The dark raster retains the system-composed tile and lighting in `Previews/Dark.png`; keep both copies in sync if that approved artwork changes. `Prebuilt/AppIcon.icns` is the compatibility plate for the bundle’s default icon. Commit both after changing a source when their contents change. `make-app.sh` prefers these renders and falls back to compiling the sources when they are missing.

Verify migration and every bundled selection with `scripts/check-app-icons.sh`.
