# Materialize (Godot port)

A work-in-progress **Godot 4** port of [Materialize](https://github.com/Unity-Technologies/com.unity.materialize),
the Unity sample tool (Unity Technologies / Aras Pradito, 2013) that builds PBR
texture maps from a source image. Everything here is original Godot code derived
from the Unity source, so the project stays fully open source.

- **Godot:** 4.7.1 stable, Forward Plus (available as `/usr/bin/godot`)
- **License:** GPL-3.0 (`LICENSE`), inherited from the original project — any
  derivative must stay under GPL-3.0.
- **Unity source (read-only reference, not committed here):**
  `/home/tiny/AI/materialize/Materialize` (Unity 2017.4.8f1 project)
- **Docs:** `docs/how_materialize_works.md` — how Materialize works, pass by
  pass, and how the port reproduces it.

## What the tool does

Materialize is a windowed GUI tool. The user loads a diffuse image, then drives a
chain of GPU "blit" passes, each with its own slider set, to derive maps:

| Map | Derived from |
| --- | --- |
| Height | Diffuse (multi-scale blur + average subtraction + contrast/gain) |
| Normal | Height (sobel / sobol / sphere / height-blur variants) |
| Edge | Normal (detect creases, re-render normal map) |
| AO | Normal (ray-marched hemisphere sampling, MSAO) |
| Metallic | Diffuse + height + normal (thresholds + blur masks) |
| Smoothness | Diffuse + metallic + specular-style heuristics |
| Diffuse edit | Hue/sat/val, levels, blur, clone-stamp style paint |
| Alignment | Diffuse / normal gradient → anisotropic alignment map |
| Seamless tiling | Patch-mixing to make a tileable map |
| Post process | Global depth-of-field / motion blur / TAA on the preview |
| Preview | DNMST (diffuse-normal-metal-smooth-thickness) surface shader on a test mesh, with cubemap lighting |

Finally, the maps are exported to disk (the original supports bmp/jpg/png/tga/tiff),
and a project file (XML) stores every tool's settings plus the map paths.

## Current status

The app is laid out like Materialize's window, and **Height From Diffuse and Edit
Diffuse are ported and running on the GPU**: the stone test pattern feeds the
source, the panel's sliders regenerate the map, and the generated map goes live
onto the `MeshInstance3D` preview.

```
MapModules/map_module.gd              the module contract (map_type/settings/panel_scene/generate/preview)
MapModules/heightMap/                 the Height module:
  height_from_diffuse.gd              settings, presets, gain mapping, generate() coroutine
  height_from_diffuse.gdshader        passes: SAMPLE / BLUR / COMBINE / AVG
  height_panel.tscn + .gd            the tool panel, laid out like HeightFromDiffuseGui.cs
  height_map_module.gd               the module that binds the generator and the panel
MapModules/diffuseMap/                the Diffuse module:
  edit_diffuse.gd                     settings + generate() coroutine
  edit_diffuse.gdshader              passes: BLUR / EDIT (fragEditDiffuse)
  diffuse_panel.tscn + .gd           the tool panel, laid out like EditDiffuseGui.cs
  diffuse_map_module.gd              the module that binds the generator and the panel
core/blit.gd                          pass framework (SubViewport + quad + ShaderMaterial)
core/test_pattern.gd                  procedural stone source (no assets needed)
shaders/mesh_preview.gdshader         the 3D preview material (map + Height Reveal Slider + Diffuse split)
ui/map_box.gd + scenes/map_panel.tscn the map box (preview, P C O S, Quick Save, Preview, Create, Clear)
ui/collapse_group.gd                  foldable container (header row + foldable body), used by the Height panel's colour samples
scenes/main.tscn + scripts/main.gd    the app shell: box row, panel slot, mesh, dialogs, toolbar, roadmap
scenes/save_panel.tscn                the saving box (file format + Save all maps!)
tests/                                blit probe, end-to-end height + diffuse tests, CPU references, live preview check, panel fold check
docs/how_materialize_works.md         algorithm + design notes
```

The first GPU run (RTX 3080, Forward+) passed: the stone source generates a
1024² height map, and the GPU output matches the CPU reference in
`tests/height_cpu.tscn` (mean 0.498 exact, min/max within 0.05 — the CPU
reference approximates the shader's edge-tap window fade). `tests/live_preview.tscn`
drives the panel like a user and checks the whole chain: the map lands on the mesh,
the Height Reveal Slider writes the mesh material's `reveal` uniform with no pass
chain, the "Details" weight preset goes through settings → debounce → pass chain,
and the map checksum moves, which is what proves the uniforms reached the shader.

The second GPU run passed the same way for Diffuse: `tests/diffuse_cpu.tscn`
compares the GPU pass chain against the CPU port of `fragEditDiffuse`
(neutral mean 0.499, max pixel delta 0.0004; strong settings mean 0.611, delta
0.0005), `tests/diffuse_test.tscn` runs the 1024² chain, checking that the neutral
mean sits in the reference band (0.510, CPU 0.499) and that a strong setting change
moves the map, and `tests/diffuse_live.tscn` drives the panel like a user: the
Diffuse Reveal Slider writes `split_reveal` on the mesh material with no pass
chain, the generation sliders regenerate from the pristine source, "Set as Diffuse"
re-runs the chain, and Clear restores the source for the split preview — all PASS.

The app: load a diffuse image (PNG/JPG) or press **Stone Test Pattern**, pick a
resolution (512 / 1024 / 2048 / source size), adjust sliders — the tool regenerates
live (debounced), the map box preview and the mesh update, and **Save Map** writes a
PNG. Clicking a box's **Create** makes that map active: its panel slots into
`MapOptionsPanel` and its map goes onto the mesh. Height (1st) and Diffuse (2nd)
are ported, so their Create buttons are live; the unported maps' Create buttons
are disabled, and the status line names the Unity file each one still needs.
Quick Save writes `user://materialize<suffix>.png` (Materialize appends the map
suffix, `MainGui.cs` lines 543-547); the map store keys the pristine source as
`maps["diffuse_original"]` (Unity's `_DiffuseMapOriginal`) beside the edited
`maps["diffuse"]`.

### Deviations from Materialize

- The Height Reveal Slider defaults to 1.0 (Materialize's `HFDS.Slider` defaults to
  0.5), so the mesh shows the map in full from the first run. The Diffuse Reveal
  Slider keeps Materialize's 0.5 default (`EDDS.Slider`), and it splits the mesh
  preview instead of mixing towards grey (see the split note below).
- Materialize draws 8 `-` markers between the contrast faders' zero line; the panel
  omits them (Godot has no equivalent decoration).
- Colour picking uses the map box preview's UV (the box forwards clicks as
  `preview_clicked`), not Materialize's 3D mesh raycast.
- The two colour sample blocks are foldable containers (`ui/collapse_group.gd`).
  Materialize has no fold control: `HeightFromDiffuseGui.cs` draws every control
  at a fixed rect inside a 300 x 590 px window. Godot stacks the groups in one
  column, and the open sample bodies demand 400 px of faders each, which widened
  the panel to 541 px and pushed "Set as Height Map" past the window. Each
  sample is now a `CollapseGroup`: its header keeps "Use Color Sample N" and
  "Isolate Mask" reachable while the body is hidden, a sample's body folds when
  its Use box goes off (Unity draws the swatch, "Pick Color", and the faders
  only inside `if (HFDS.UseSampleN)`, lines 714-751, 760-797), and the fold
  button opens a sample the user has switched off without writing settings.
  Folded, the panel is 400 x 648 px; open it is 541 x 1450 px. The button labels
  are `+` / `-`, because Godot's fallback font has no arrow glyphs.
- BMP/TGA/TIFF export fall back to PNG with a status note: Unity used
  `FreeImage.dll`, which has no Godot equivalent.
- A toolbar row (Load Diffuse, Stone Test Pattern, Resolution, Generate, Save Map,
  status) is port-only: Materialize's window has no status line.
- "Use Normal as input" swaps the sample controls for Spread/SpreadBoost in Unity;
  it is not implemented, since Normal From Height is not ported.

## Repository layout

```
project.godot          Godot 4 project, main scene = scenes/main.tscn
scenes/                the app shell, the map box scene, the saving box scene
scripts/               the app shell script
MapModules/            one folder per texture map (the module contract in map_module.gd)
  heightMap/           generator + shader + panel + module: the reference implementation
  diffuseMap/          generator + shader + panel + module: the second ported tool
core/                <- shared framework: blit.gd, test_pattern.gd
shaders/             <- app-level shaders (the preview material), not per-map generators
ui/                  <- map_box.gd + collapse_group.gd (generic widgets, so they are not per-map)
docs/                <- how_materialize_works.md
assets/cubemaps/       <- cube maps for the preview lighting (empty, deferred)
assets/models/         <- preview meshes (the Unity FBX test objects, deferred)
assets/textures/       <- stock maps (flat white / black / grey / normal, deferred)
tests/                 <- framework probe + generator tests + live preview check + panel fold check
```

Each map lives in its own `MapModules/<map>Map/` folder once ported; the roadmap
print in `scripts/main.gd` lists which Unity file each one comes from. Height
(1st) and Diffuse (2nd) are ported; Normal, Metallic, Smoothness, Edge, AO are
next. Diffuse uses the same module contract plus two preview hooks
(`source_map_type()`, `preview_split()`), described in
`docs/how_materialize_works.md`.

## Unity -> Godot mapping

| Unity | Godot |
| --- | --- |
| `Graphics.Blit(src, dst, mat, pass)` | `SubViewport` (`use_hdr_2d`, cleared, `UPDATE_ALWAYS`) + full-screen `QuadMesh` with a `ShaderMaterial`; `pass` uniform picks the pass |
| readback | `viewport.get_texture().get_image()` after `RenderingServer.frame_post_draw` |
| `RenderTexture` (RFloat / Linear, `wrapMode = Repeat`) | working `Image` in `FORMAT_RGBAF` in CPU RAM, uploaded per pass as `ImageTexture`; samplers declared `filter_linear, repeat_enable` |
| `Shader` / CGINCLUDE fragment programs | `.gdshader` (canvas_item fragment, `SCREEN_UV`) |
| `Shader_SetFloat` / `SetTexture` | `material.set_shader_parameter()`, `Image` values auto-uploaded |
| `OnGUI` panels with sliders | `Control` scenes + `HSlider`, `VSlider`, `CheckBox`, `Button`, `ColorPicker`, `OptionButton` |
| `GUI.Box` / `GUI.Label` / `GUI.Button` layout | `PanelContainer` + `Label` + `Button`, sized from `MainGui.cs`'s pixel rectangles |
| `_GamaCorrection` (`pow(x, 2.2)`) | dropped: the port works in raw 0..1 file values throughout |
| `FreeImage.dll` (Targa/bmp/tiff io) | `Image.load_from_file`, `save_png/save_jpg/save_webp` (BMP/TIFF/TGA export need a writer) |
| `TargaImporter.cs` | not needed: Godot loads `.tga` natively |
| FBX test meshes | Godot cannot import FBX → convert to `.glb` with Blender/FBX-Convert and commit the glTF |
| `.psd` GUI icons | not supported → convert to `.png` |
| XML project save (`SaveLoadProject.cs`) | `ConfigFile` (`.ini`) or `JSON` |

Design note: each map lives in `MapModules/<map>Map/` as a `MapModule` node
(`map_type()`, `map_title()`, `save_suffix()`, `settings()`, `panel_scene()`,
`generate(source, blit)`, `preview(map)`, `create_available(maps)`, `set_map()`,
`clear_map()`, plus the preview hooks `source_map_type()` and `preview_split()`)
wrapping a generator resource class that exposes `settings` (a
`Dictionary` with the same slider names the Unity GUI uses). The app shell owns the
`Blit` node, the source image, the map store, the panel slot, and the mesh, so a
module never touches shared state; a new map module plugs in without touching the
shell. All generators share one `core/blit.gd`, so a pass is "set shader params,
draw the quad, read back the image". Keeping the pyramid in CPU RAM (one
`ImageTexture` live per pass) is what makes this feasible on a machine with little
VRAM: at 1024² the combine pass holds 8 float textures (~128 MB), not the whole
pyramid.

The Height Reveal Slider is a preview control, so it is not blended into the map:
the mesh preview material (`shaders/mesh_preview.gdshader`) mixes the map towards
mid-grey by `reveal` on the GPU, which makes dragging the slider free.

The Diffuse Reveal Slider is also a preview control, and it is not blended
either: Materialize splits the preview (`Edit_Diffuse_Preview.shader`'s `_Slider`
picks `_MainTex` on one side and `_ResultTex` on the other), so the mesh material
shows the source image left of the seam and the edited map right of it. The seam
is a uniform write, `split_reveal`, the same way Height's grey mix is.

## Port order

One tool per commit, in dependency order (later tools consume earlier outputs):

0. **Skeleton** — project, git, roadmap shell. Done.
1. **Blit framework** — `core/blit.gd`. Done, validated on the GPU by the probe.
2. **Height From Diffuse** — ported, wired into the app, panel and live mesh output
   validated on the GPU. Done.
3. Normal From Height
4. Edge From Normal
5. AO From Normal
6. Metallic
7. Smoothness
8. **Edit Diffuse** — ported second (out of list order): its passes only read the
   source image, so it came in right after the first module. Done.
9. Alignment
10. Seamless Tiling
11. Material preview (DNMST) + cubemap lighting + test meshes
12. Export (file formats) + project save/load

For each tool: read the Unity `.cs` GUI + `Blit_*.shader`, port the shader to
`.gdshader`, port the GUI panel into `MapModules/<map>Map/`, wire the settings to
the shader through the module contract, compare the output against a reference
render from the Unity tool.

## Known gaps to decide later

- "Use Normal as input" for Height From Diffuse (Unity's `ProcessNormal()`,
  Spread/SpreadBoost) needs a normal map source → comes with Normal From Height.
- Unity stacks the Diffuse blurs as `2 * ceil(2 * blurSize)` narrow passes
  (Blit_Shader pass 1, run per axis). Each Godot pass costs a frame, so the port
  runs one horizontal and one vertical pass per map with the full radius and the
  same raised-cosine window. The spread and the kernel shape match; the stacked
  passes' Gaussian tail is approximated. The CPU reference in
  `tests/diffuse_cpu.gd` runs the same single-pair kernel, so the GPU-vs-CPU
  check measures the chain, not the stacking difference.
- Unity's average map is computed at 256²; the port runs it at full resolution.
  Full resolution is a finer reference and avoids viewport resizing mid-chain.
- Unity shaders use `_MainTex_Tint` style multi-sample blur chains; Godot does
  the same with separable taps. Compute shaders (`compute_shaders`, Vulkan)
  would make AO/edge passes cheaper later.
- BMP/TIFF/TGA export needs a custom writer; PSD icons need PNG conversion;
  FBX meshes need `.glb` conversion.

## Run

```
cd ~/Godot/materialize
godot --headless --path . --import  # rebuild the class cache + .uid files
godot --path . --headless --quit     # parse check + roadmap print (no GPU)
godot --headless --quit --path . res://tests/height_cpu.tscn  # CPU math reference, ~100 s, no GPU
godot --path .                       # opens the app
DISPLAY=:1 godot --path . res://tests/live_preview.tscn  # live mesh + panel chain, writes user://live_preview_*.png
DISPLAY=:1 godot --path . res://tests/blit_probe.tscn    # framework probe (readback, HDR, repeat wrap, blur taps)
DISPLAY=:1 godot --path . res://tests/height_test.tscn   # end-to-end, writes user://height_test/*.png
DISPLAY=:1 godot --path . res://tests/diffuse_cpu.tscn   # CPU reference of fragBlur + fragEditDiffuse, no GPU
DISPLAY=:1 godot --path . res://tests/diffuse_test.tscn  # end-to-end, writes user://diffuse_test/*.png
DISPLAY=:1 godot --path . res://tests/diffuse_live.tscn  # live split-screen preview + panel chain
godot --headless --path . res://tests/panel_fold.tscn     # colour sample fold layout check, no GPU
```

The live preview test prints the map statistics and the panel chain checks; it also
saves `live_preview_window.png`, a screenshot of the running app. On Linux,
`user://` is `~/.local/share/godot/app_userdata/materialize/`.
