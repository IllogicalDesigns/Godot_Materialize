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

Commit 2: the blit framework plus **Height From Diffuse** is ported and wired
into the app, and its **math is validated on the CPU** by `tests/height_cpu.tscn`
(no GPU, no VRAM needed). Fixes after the first user run: the combine pass was
missing Unity's `+ 0.5` per level, which made every height map come out pure
black; the previews now keep the image's aspect ratio (`STRETCH_KEEP_ASPECT_CENTERED`)
instead of stretching it to the panel.

```
core/blit.gd                        pass framework (SubViewport + quad + ShaderMaterial)
core/height_from_diffuse.gd         settings, presets, gain mapping, generate() coroutine
shaders/height_from_diffuse.gdshader  passes: SAMPLE / BLUR / COMBINE / AVG
core/test_pattern.gd                procedural stone source (no assets needed)
ui/height_panel.tscn + .gd          hand-authored control panel (Unity OnGUI equivalent)
scenes/main.tscn + scripts/main.gd  previews, toolbar, colour picking, debounce, roadmap
tests/                              blit probe, end-to-end height test, CPU reference
docs/how_materialize_works.md       algorithm + design notes
```

The app: load a diffuse image (PNG/JPG) or press **Stone test pattern**, pick a
resolution (512 / 1024 / 2048 / source size), adjust sliders — the tool
regenerates live (debounced), and **Save PNG** writes the height map.
**Pick** arms colour sampling; clicking the source preview feeds a sample colour.

**No GPU pass has been executed yet** — the machine has no VRAM headroom, so the
shader code is written from the class reference and validated only by headless
parse/import. The CPU reference test (`tests/height_cpu.tscn`) checks the
algorithm independently of the GPU, so math bugs and shader bugs can be told
apart. See `docs/how_materialize_works.md` section 7 for the exact test commands
to run when VRAM frees up. Expect the first GPU run to surface shader syntax
issues; the framework probe prints expected values for every behaviour it checks
(readback, HDR, repeat wrap, blur taps).

## Repository layout

```
project.godot          Godot 4 project, main scene = scenes/main.tscn
scenes/                UI scenes (the tool shell lives in scenes/main.tscn)
scripts/               UI / app-level GDScript
core/                  <- GDScript ports of the texture generators (one file per tool)
shaders/               <- .gdshader ports of the Unity shaders (one per tool)
ui/                    <- per-tool control panels (the Unity OnGUI panels)
docs/                  <- how_materialize_works.md
assets/cubemaps/       <- cube maps for the preview lighting (empty, deferred)
assets/models/         <- preview meshes (the Unity FBX test objects, deferred)
assets/textures/       <- stock maps (flat white / black / grey / normal, deferred)
tests/                 <- framework probe + end-to-end generator tests
```

## Unity -> Godot mapping

| Unity | Godot |
| --- | --- |
| `Graphics.Blit(src, dst, mat, pass)` | `SubViewport` (`use_hdr_2d`, cleared, `UPDATE_ALWAYS`) + full-screen `QuadMesh` with a `ShaderMaterial`; `pass` uniform picks the pass |
| readback | `viewport.get_texture().get_image()` after `RenderingServer.frame_post_draw` |
| `RenderTexture` (RFloat / Linear, `wrapMode = Repeat`) | working `Image` in `FORMAT_RGBAF` in CPU RAM, uploaded per pass as `ImageTexture`; samplers declared `filter_linear, repeat_enable` |
| `Shader` / CGINCLUDE fragment programs | `.gdshader` (canvas_item fragment, `SCREEN_UV`) |
| `Shader_SetFloat` / `SetTexture` | `material.set_shader_parameter()`, `Image` values auto-uploaded |
| `OnGUI` panels with sliders | `Control` scenes + `HSlider`, `CheckBox`, `Button`, `ColorPicker`, `OptionButton` |
| `_GamaCorrection` (`pow(x, 2.2)`) | dropped: the port works in raw 0..1 file values throughout |
| `FreeImage.dll` (Targa/bmp/tiff io) | `Image.load_from_file`, `save_png/save_jpg/save_webp` (BMP/TIFF/TGA export need a writer) |
| `TargaImporter.cs` | not needed: Godot loads `.tga` natively |
| FBX test meshes | Godot cannot import FBX → convert to `.glb` with Blender/FBX-Convert and commit the glTF |
| `.psd` GUI icons | not supported → convert to `.png` |
| XML project save (`SaveLoadProject.cs`) | `ConfigFile` (`.ini`) or `JSON` |

Design note: every generator is a `core/<tool>.gd` resource class exposing
`settings` (a `Dictionary` with the same slider names the Unity GUI uses) and
`generate(source: Image, blit: Blit) -> Image`. All generators share one
`core/blit.gd`, so a pass is "set shader params, draw the quad, read back the
image". Keeping the pyramid in CPU RAM (one `ImageTexture` live per pass) is
what makes this feasible on a machine with little VRAM: at 1024² the combine
pass holds 8 float textures (~128 MB), not the whole pyramid.

## Port order

One tool per commit, in dependency order (later tools consume earlier outputs):

0. **Skeleton** — project, git, roadmap shell. Done.
1. **Blit framework** — `core/blit.gd`. Done (untested on GPU).
2. **Height From Diffuse** — ported, wired into the app, math validated on the
   CPU. Untested on GPU.
3. Normal From Height
4. Edge From Normal
5. AO From Normal
6. Metallic
7. Smoothness
8. Edit Diffuse
9. Alignment
10. Seamless Tiling
11. Material preview (DNMST) + cubemap lighting + test meshes
12. Export (file formats) + project save/load

For each tool: read the Unity `.cs` GUI + `Blit_*.shader`, port the shader to
`.gdshader`, port the GUI panel into `ui/`, wire the settings to the shader,
compare the output against a reference render from the Unity tool.

## Known gaps to decide later

- "Use Normal as input" for Height From Diffuse (Unity's `ProcessNormal()`,
  Spread/SpreadBoost) needs a normal map source → comes with Normal From Height.
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
godot --path . --headless --quit      # parse check + roadmap print (no GPU)
godot --headless --quit --path . res://tests/height_cpu.tscn  # CPU math reference, ~100 s, no GPU
godot --path .                        # opens the app
DISPLAY=:1 godot --path . res://tests/blit_probe.tscn    # framework probe (needs GPU)
DISPLAY=:1 godot --path . res://tests/height_test.tscn   # end-to-end, writes user://height_test/*.png
```
