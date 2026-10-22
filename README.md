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

## What the tool does

Materialize is a windowed GUI tool. The user loads a diffuse image, then drives a
chain of GPU "blit" passes, each with its own slider set, to derive maps:

| Map | Derived from |
| --- | --- |
| Height | Diffuse (multi-pass blur + contrast + depth/sharpen) |
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

## Repository layout

```
project.godot          Godot 4 project, main scene = scenes/main.tscn
scenes/                UI scenes (the tool shell lives in scenes/main.tscn)
scripts/               UI / app-level GDScript
core/                <- GDScript ports of the texture generators (one file per tool)
shaders/             <- .gdshader ports of the Unity shaders (one per tool)
ui/                  <- per-tool control panels (the Unity OnGUI panels)
assets/cubemaps/     <- cube maps for the preview lighting
assets/models/       <- preview meshes (the Unity FBX test objects)
assets/textures/     <- stock maps (flat white / black / grey / normal)
tests/               <- headless checks (run a pass, compare output image)
```

`core/`, `shaders/`, `ui/`, `assets/` and `tests/` are empty placeholders right
now: the skeleton commit only carries the project shell.

## Unity -> Godot mapping

| Unity | Godot |
| --- | --- |
| `Graphics.Blit(src, dst, mat)` | `SubViewport` + full-screen `ShaderMaterial`, output read back with `Image.create_from_viewport()` |
| `Shader` / CGINCLUDE fragment programs | `.gdshader` (canvas_item fragment, screen-space UV) |
| `Shader_SetFloat` etc. on materials | `material.set_shader_parameter()` |
| `OnGUI` panels with sliders | `Control` scenes + `HSlider`/`VSlider`, `CheckButton`, `OptionButton` |
| `Texture2D` / `RenderTexture` | `Image` + `ResourceLoader` + `ViewportTexture` |
| `FreeImage.dll` (Targa/bmp/tiff io) | `Image.load_*/save_*`, `Image.save_png/save_jpg/save_webp` (BMP/TIFF/TGA export need a writer — see notes) |
| `TargaImporter.cs` | not needed: Godot loads `.tga` natively |
| FBX test meshes | Godot cannot import FBX → convert to `.glb` with Blender/FBX-Convert and commit the glTF |
| `.psd` GUI icons | not supported → convert to `.png` |
| XML project save (`SaveLoadProject.cs`) | `ConfigFile` (`.ini`) or `JSON` |

Design note: every generator becomes a `core/<tool>.gd` resource class exposing
`settings` (a `Dictionary` of the same slider names the Unity GUI uses) and
`generate(input: Image) -> Image`. All of them share one `core/blit.gd` that owns
the `SubViewport`, so a pass is "set shader params, draw quad, read back image".
That keeps each tool independent and unit-testable in headless mode.

## Port order

One tool per commit, in dependency order (later tools consume earlier outputs):

0. **Skeleton** (this commit) — project, git, roadmap shell.
1. `core/blit.gd` + preview scene (framework, no generator yet)
2. Height From Diffuse
3. Normal From Height
4. Edge From Normal
5. AO From Normal
6. Metallic
7. Smoothness
8. Edit Diffuse
9. Alignment
10. Seamless Tiling
11. Material preview (DNMST) + cubemap lighting + test meshes
12. Export (file formats) + project save/load + settings UI

For each tool: read the Unity `.cs` GUI + `Blit_*.shader`, port the shader to
`.gdshader`, port the GUI panel into `ui/`, wire the settings to the shader,
compare the output image against a reference render from the Unity tool.

## Known gaps to decide later

- Unity shaders use `sampler2D` loops + `_MainTex_Tint` style multi-sample blurs;
  Godot fragment shaders can do the same, but the "7 blur textures" multi-pass
  blit needs a ping-pong render target in `core/blit.gd`.
- Unity's `_GamaCorrection` (gamma pipeline) does not exist in Godot; decide
  whether to keep sRGB-linear conversions per pass.
- Compute-shader option: Godot 4.3+ `compute_shaders` would make AO/edge passes
  cheaper, but only on the Vulkan/Metal backends; the `.gdshader` route is portable.

## Run

```
cd ~/Godot/materialize
godot --path . --headless --quit      # checks scripts, prints the roadmap
godot --path .                        # opens the skeleton window
```
