<!-- Fragment for art/CREDITS.md: third-party inputs of the Blender renders
     (art/blender/). Pinned URLs + sha256 are in art/blender/sources.json. -->

### Blender renders (tiles, anvil face, mold cells, app icon, backgrounds)

All 3D models, scenes, lighting and shaders are original work made with the bpy scripts in
`art/blender/`. Textures are baked into the rendered images; nothing below ships in the app as-is.

| File(s) | Source | Author | Licence | Used for | Retrieved |
|---|---|---|---|---|---|
| Metal052C (1K-JPG) | https://ambientcg.com/view?id=Metal052C | ambientCG (Lennart Demes) | CC0 1.0 | iron roughness/normal detail: letter tiles, anvil face, mold-cell plate, anvils & hammers | 2026-10-17 |
| Ground054 (1K-JPG) | https://ambientcg.com/view?id=Ground054 | ambientCG | CC0 1.0 | casting sand of `cell_empty` | 2026-10-17 |
| Bricks102 (1K-JPG) | https://ambientcg.com/view?id=Bricks102 | ambientCG | CC0 1.0 | stone walls, forge apron, embankment (`bg_hall`, `bg_copper`) | 2026-10-17 |
| Bricks094 (1K-JPG) | https://ambientcg.com/view?id=Bricks094 | ambientCG | CC0 1.0 | forge / hearth / chimney bricks (all backgrounds) | 2026-10-17 |
| Planks023A (1K-JPG) | https://ambientcg.com/view?id=Planks023A | ambientCG | CC0 1.0 | wood: beams, stumps, barrels, handles, doors, water wheel | 2026-10-17 |
| PavingStones142 (1K-JPG) | https://ambientcg.com/view?id=PavingStones142 | ambientCG | CC0 1.0 | flagstone floors | 2026-10-17 |
| RoofingTiles014B (1K-JPG) | https://ambientcg.com/view?id=RoofingTiles014B | ambientCG | CC0 1.0 | clay roof tiles (`bg_copper`, `bg_tin`) | 2026-10-17 |
| Ground037 (1K-JPG) | https://ambientcg.com/view?id=Ground037 | ambientCG | CC0 1.0 | grassy ground / river banks (`bg_tin`, `bg_copper`) | 2026-10-17 |
| Plaster007 (1K-JPG) | https://ambientcg.com/view?id=Plaster007 | ambientCG | CC0 1.0 | plaster walls (`bg_tin`, `bg_copper`) | 2026-10-17 |
| Roboto Slab (variable TTF) | https://fonts.google.com/specimen/Roboto+Slab (via github.com/google/fonts) | Christian Robertson | Apache 2.0 | the 3D "W" on the app icon (rendered into `art/icon/*`) | 2026-10-17 |

CC0 assets need no attribution; they are listed for provenance. Roboto Slab's licence text is saved at
`art/third_party/blender/fonts/LICENSE-RobotoSlab.txt` (fetched by `art/blender/fetch_assets.py`).
