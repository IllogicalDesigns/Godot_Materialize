# How Materialize works

Materialize (Unity Technologies, 2013, GPLv3) turns a single photograph into a
set of PBR texture maps: diffuse, height, normal, edge, ambient occlusion,
metallic, smoothness. It does this by running a chain of full-screen GPU shader
passes over the image, each pass writing into a render texture that feeds the
next pass. Every tool is a `.cs` GUI panel (Unity `OnGUI` sliders) plus one or
more `Blit_*.shader` fragment programs.

This document explains the algorithm as the Unity source does it, and how the
Godot port (`MapModules/`, `core/`, `shaders/`, `ui/`, `scenes/`) reproduces it.
The first ported tool is Height From Diffuse, in `MapModules/heightMap/`; the same
pattern applies to every other tool.

## 1. The blit architecture

Unity:

```csharp
Graphics.Blit(sourceTexture, destinationRenderTexture, blitMaterial, passIndex);
```

`Graphics.Blit` draws a full-screen quad with `blitMaterial`, sampling
`_MainTex` (the source) and writing `COLOR` into the destination render
texture. The pass index selects one of the shader's SubShader passes, so one
`.shader` file holds every stage of a tool. Render textures use
`wrapMode = Repeat`, so sampling outside 0..1 wraps around — that is what keeps
generated maps tileable.

Godot (in `core/blit.gd`):

- an offscreen `SubViewport` with `use_hdr_2d = true` (HDR linear canvas),
  `transparent_bg = true`, cleared every frame, `UPDATE_ALWAYS`;
- a full-screen `MeshInstance2D` + `QuadMesh` sized to the viewport, with a
  `ShaderMaterial` holding the tool's `.gdshader`;
- a pass = `set_shader_parameter(...)` + draw + read back with
  `viewport.get_texture().get_image()` after `RenderingServer.frame_post_draw`.

Everything is stored between passes as `Image` in `FORMAT_RGBAF` (32-bit float
per channel) in CPU RAM, and uploaded as one `ImageTexture` per pass. Keeping
the pyramid in RAM rather than in GPU textures is what keeps VRAM usage at tens
of megabytes instead of hundreds — the working set at 1024² is a few images
live on the GPU at a time.

Float formats matter for a second reason: Godot applies an sRGB→linear
conversion to 8-bit textures, and Materialize's convention is *raw 0..1 file
numbers* with **0.5 = neutral**. Float formats preserve the numbers exactly, so
a pass sees precisely what the previous pass wrote.

Samplers are declared with `repeat_enable` to match Unity's `Repeat` wrap mode,
and with `filter_linear` for the sub-pixel taps the blur kernels need.

## 2. Height From Diffuse

Unity: `Scripts/HeightFromDiffuseGui.cs` (`ProcessDiffuse()`), with
`Shaders/Resources/Blit_Sample.shader` (colour sampling) and
`Shaders/Resources/Blit_Shader.shader` (blur pass 1, combine pass 2).
Godot: `MapModules/heightMap/height_from_diffuse.gd` +
`MapModules/heightMap/height_from_diffuse.gdshader`, passes 0..3.

The core idea: **height is local relief, not brightness**. A photograph lit
from one side has a big, slow luminance ramp across the frame. If you build a
height map from brightness, that ramp becomes a slope in the height map, and
the normal map derived from it gets a large smooth tilt across the whole surface
— an artifact. Materialize removes the low-frequency lighting component and
keeps only detail at each scale, so a stone wall produces height from the
joints and the grain, not from the sky-lit gradient.

Four stages:

### Stage 1 — sample pass (pass 0)

Convert the source to the base grey height:

```
base = r * 0.3 + g * 0.5 + b * 0.2
```

Materialize uses these weights, not the standard luminance weights.

Two optional "colour samples" can push specific pixels to chosen heights, which
is how you tell the tool "these bright patches are stone, these dark patches
are soil". A sample works by HSL closeness: the picked colour is converted to
HSL, the pixel is converted to HSL, and a weighted mask is built from
hue difference (with hue wrapping, comparing the three candidate distances),
saturation difference and luminance difference. Weights `HueWeight`,
`SatWeight`, `LumWeight` (defaults 1.0 / 0.5 / 0.2) are normalised by their
sum, then windowed by `smoothstep(MaskLow, MaskHigh, mask)`.

The mask blends the base toward `SampleHeight` by `mask * SampleBlend`,
sample 2 first, then sample 1, so sample 1 wins where both masks are active.
`Isolate` modes output the mask itself (used to dial in the mask window
visually). When neither sample is used, `SampleBlend` is forced to 0.

### Stage 2 — the blur pyramid (passes 1 x 2, six levels)

A scale ladder of six images, each a blur of the previous one. The blur kernel
is Materialize's `fragBlur`: a **separable** box blur with a raised-cosine
window, 4 taps on each side of the centre (9 taps total per axis), run once
horizontally then once vertically. The window `cos(i / 8 * 2π) * 0.5 + 0.5`
fades the edge taps to zero, so consecutive levels stack without hard seams.

The radius grows geometrically. Materialize's exact sequence is
`1, 1 + e, 1 + 3e, 1 + 7e, 1 + 15e, 1 + 31e` where `e = ((width + height) / 2) / 1024`.
At 1024² `e = 1` and the sequence is 1, 2, 4, 8, 16, 32 pixels — each level
doubles the radius. At other resolutions `e` scales the ladder with the image,
which is why the same slider set behaves the same on a 512 or 2048 source.

`BlurContrast` in the pyramid runs at 1.0 (identity); the per-level
`BlurContrast` sliders act in the combine pass, not in the blur.

### Stage 3 — the average map (pass 3 x 2)

The heavily blurred level 6 is blurred once more with 32 taps per side at 64×
the base radius, horizontally then vertically. The result is the *local
low-frequency reference* — Materialize's `_AvgMap`, computed at 256² in the
original. Godot computes it at full resolution (`average_blur`, 65 taps),
which is a little cheaper on VRAM bookkeeping and gives a finer reference.

### Stage 4 — combine (pass 2)

For every level, the contribution is its deviation from the average map,
gamma-lifted, scaled by that level's contrast, offset to mid-grey, and weighted:

```
contribution[i] = ((pow(level[i], 0.45) - pow(avg, 0.45)) * contrast[i] + 0.5) * weight[i]
height = sum(contribution) / sum(weight)
```

Three details carry the whole look:

- `pow(x, 0.45)` lifts midtones so fine detail survives in dark areas. With a
  plain subtraction, a dark brick's grain is smaller than the noise floor of
  the average; the lift makes it visible.
- Subtracting `pow(avg, 0.45)` kills the lighting gradient: what remains is
  relief at the scale of each level.
- The `+ 0.5` inside each contribution is what keeps the sum centred. A flat
  source makes every deviation 0, so the weighted average lands on 0.5 —
  neutral mid-grey. Without it the sum collapses to 0, `(0 - 0.5) * 1.5 + 0.5`
  is negative, the clamp takes it to 0, and the output is pure black. The first
  Godot port shipped exactly this bug; `tests/height_cpu.tscn` is the check for
  it (a flat source must give 0.500 everywhere).

Then the final polish:

```
height = (height - 0.5) * FinalContrast + 0.5 + FinalBias   (clamped)
height > 0.5:  pow(2h - 1, gain) * 0.5 + 0.5
height < 0.5:  1 - (pow(2(1-h) - 1, gain) * 0.5 + 0.5)
```

Split gain pushes the bright and dark halves apart around the neutral mid-grey,
mirrored so the map grows symmetrically. The UI slider (-1..1) is mapped to the
exponent before use: `gain >= 0 → gain + 1`, `gain < 0 → abs(1 / (gain - 1))`.
A slider of 0 means exponent 1 = no gain change. Materialize does this mapping
in C# (`ProcessHeight()`), so `HeightFromDiffuse.gain_mapping` does the same.

Defaults (`HeightFromDiffuseSettings` constructor):
weights `0.15, 0.19, 0.3, 0.5, 0.7, 0.9, 1.0`,
contrasts all `1.0`, `FinalContrast 1.5`, `FinalBias 0.0`, `FinalGain 0.0`,
sample 1: hue 1.0 / sat 0.5 / lum 0.2 / mask 0..1 / height 0.5,
sample 2: same with height 0.3, `SampleBlend 0.5`.

Presets, straight from the Unity buttons:

- weights default / **Detail** `[0.7, 0.4, 0.3, 0.5, 0.8, 0.9, 0.7]` /
  **Displace** `[0.02, 0.03, 0.1, 0.35, 0.7, 0.9, 1.0]`
- contrast default / **Cracked Mud** `[1, 1, 1, 1, -0.2, -2, -4]` /
  **Funky** `[-3, -1.2, 0.3, 1.3, 2.0, 2.5, 2.0]`

Negative contrasts invert a level, which turns bumps into creases — Cracked Mud
uses that to make the wide scales carve cracks while the sharp levels keep the
surface relief.

## 3. Edit Diffuse

Unity: `Scripts/EditDiffuseGui.cs` (the "Edit Diffuse" window, `EDDS` settings),
with `Shaders/Resources/Blit_Shader.shader` pass 1 (the blur) and pass 11
(`fragEditDiffuse`).

Godot: `MapModules/diffuseMap/edit_diffuse.gd` +
`MapModules/diffuseMap/edit_diffuse.gdshader`, passes 1 BLUR and 2 EDIT.

The core idea: **the diffuse map is the photograph minus its lighting**. A photo
has a slow illumination ramp (the average colour the stone wall absorbs) riding on
top of the local colour detail. The tool removes the ramp, keeps the detail, and
puts the source hue back so the map does not read as flat grey.

Stage 1 - two blurs. Unity runs Blit_Shader pass 1 as a separable raised-cosine
blur, stacked `2 * ceil(2 * blurSize)` times with alternating directions:

- **Overlay blur** (`Overlay Blur Size`, 5..100, default 20): the blurred copy.
  `overlay = mainTex - blurTex` is the detail the tool re-amplifies.
- **Average colour** (`Average Color Blur Size`, 5..100, default 50): the wide
  blur, the lighting ramp `fragEditDiffuse` removes. The average stays in colour
  (Unity blurs the RGB map, not grey).

Each Godot pass costs a frame, so the port runs one horizontal and one vertical
pass per map with the full radius and the same raised-cosine window. The CPU
reference (`tests/diffuse_cpu.gd`) runs the same kernel, so the GPU-vs-CPU check
measures the chain, not the stacking difference.

Stage 2 - spot removal. `avgLum = dot(mainTex, GREY)`; `lightMask` is a smoothstep
from `1 - HotSpot` up, `darkMask` a smoothstep below `DarkSpot`; the pixel is
mixed toward the average colour by `1 - (1 - lightMask) * darkMask`. Hot-spot
removal pushes bright pixels down, dark-spot removal pushes dark pixels up.

Stage 3 - lighting removal. The mask powers are remapped inside the shader
(`lightMaskPow = saturate((x - 0.5) * 2) + 1 - (1 - 1 / (saturate((x - 0.5) *
-2) + 1))`, same formula for the dark side), so 0.5 gives exponent 1, 0 gives 0.5,
1 gives 2. Then `mainTex -= avgColor`, `grey = dot(mainTex, GREY)`,
`highMask = pow(clamp(grey * 2, 0.001, 0.99), lightMaskPow)`,
`lowMask = pow(clamp(-grey * 2, 0.001, 0.99), darkMaskPow)`, `mainTex += 0.5`,
and `Remove Light` / `Remove Shadow` scale the bright and dark deviations by
those masks.

Stage 4 - overlay. `overlayMask = saturate(2 * (1 - (1 - highMask * LightPow) *
(1 - lowMask * DarkPow)) + 0.1)`, and `mainTex *= lerp(1, overlay *
BlurContrast * 10 + 1, overlayMask)`. `Overlay Blur Contrast` (default 0)
multiplies the detail; at 0 the overlay does nothing, which is why the default
chain passes through.

Stage 5 - colour restore. `hsl = RGBToHSL(mainTex)` and `hsl.xy` are replaced by
the source's hue and saturation, so the edited luminance keeps the source's
colouring. `Keep Original Color` mixes that restored colour back in, weighted by
the desaturate mask.

Stage 6 - final: `mainTex = saturate((mainTex - 0.5) * FinalContrast + 0.5 +
FinalBias)`, then `mainTex = lerp(grey, mainTex, Saturation)`.

Defaults (`EditDiffuseGui.cs` lines 46-64): `Slider 0.5`, Average Blur 50,
Overlay Blur 20, Overlay Contrast 0, Light Mask Power 0.5, Remove Light 0,
Shadow Mask Power 0.5, Remove Shadow 0, Hot Spot 0, Dark Spot 0, Final Contrast
1.0, Final Bias 0, Color Lerp 0.5, Saturation 1.0. The defaults bake the
lighting removal (Keep Original Color 0.5 keeps the source hue at the removed
luminance), so the neutral map is **not** the source image; the stone pattern's
neutral mean is 0.499 on the CPU reference.

`MapModules/diffuseMap/diffuse_panel.tscn` + `.gd` is the tool panel, laid out in
the window order `EditDiffuseGui.cs` draws (lines 495-877): Diffuse Reveal Slider
(0..1), Average Color Blur Size (5..100), Overlay Blur Size (5..100), Overlay
Blur Contrast (-1..1), Light Mask Power (0..1), Remove Light (0..1), Shadow Mask
Power (0..1), Remove Shadow (0..1), Hot Spot Removal (0..1), Dark Spot Removal
(0..1), Final Contrast (-2..2), Final Bias (-0.5..0.5), Keep Original Color
(0..1), Saturation (0..1), and `Set as Diffuse`. The panel edits the
`DiffuseGenerator.settings` `Dictionary` in place and emits `settings_changed`
(debounced regeneration) and `preview_changed` for the reveal slider.

The Diffuse Reveal Slider is Unity's `_Slider` (`Edit_Diffuse_Preview.shader`):
the test object shows the source image on one side of the seam and the edited map
on the other. `shaders/mesh_preview.gdshader` implements it as `split_reveal` +
`original`: left of the seam the shader samples the source texture, right of the
seam the map. It is a uniform write, so dragging the slider costs no pass.

The Diffuse tool reads the pristine source, Unity's `_DiffuseMapOriginal`, so the
module's `source_map_type()` is `"diffuse_original"` and the shell keeps that key
in the map store. The edited output goes to `maps["diffuse"]`, which every other
tool reads; Unity's box draws `_DiffuseMap` and falls back to
`_DiffuseMapOriginal` (`MainGui.cs` lines 574-670), so clearing the Diffuse box
restores the source as the box image.

## 4. UI (Unity OnGUI → Godot Control + map box)

The app is laid out from `MainGui.cs`'s pixel rectangles: seven map boxes
(`scenes/map_panel.tscn` + `ui/map_box.gd`, instanced as `MapPanel`..`MapPanel7`)
in a row, each with a title, a 100×100 preview, `P` `C` `O` `S`, `Quick Save`,
`Preview`, `Create` (Diffuse's button is `Edit`) and `Clear`; the saving box on
the right holds the file format list (`BMP` `JPG` `PNG` `TGA` `TIFF`) and
`Save all maps!`; the view-button row under the boxes is `Show full Material`,
`next cube map`, `Tile maps`, `Clear all texture maps`; `Quit`,
`Windowed`/`Full Screen`, `Make Suggestion` and `Hide Gui`/`Show Gui` sit in the
corners. Materialize draws these with `GUI.Box`, `GUI.Label`, `GUI.Button`; Godot
draws them with `PanelContainer`, `Label`, `Button`, in the same order
(Height, Diffuse, Normal, Metallic, Smoothness, Edge, AO).

`MapModules/heightMap/height_panel.tscn` + `.gd` is the Height tool panel, laid
out like `HeightFromDiffuseGui.cs`: the source row (`Diffuse` / `Original
Diffuse` / `Normal` as a 3-way radio), `Height Reveal Slider` (0..1),
`Frequency Weight Equalizer` with `Default` / `Details` / `Displace` and 7
vertical faders (0..1, drawn Blur6 → Blur0), `Frequency Contrast Equalizer` with
`Default` / `Cracks` / `Funky` and 7 faders (-5..5), the two colour sample
sections (`Use Color Sample 1/2`, `Isolate Mask` — mutually exclusive, as in
Unity, `Pick Color`, a compact `ColorPicker` swatch, and `Hue` / `Sat` / `Lum` /
`Low` / `High` / `Height` faders), `Sample Blend`, `Final Gain` (-0.5..0.5),
`Final Contrast` (-10..10), `Final Bias` (-1..1), and `Set as Height Map`. The
panel edits the `HeightFromDiffuse.settings` `Dictionary` in place and emits
`settings_changed`; the shell debounces a `Timer` and regenerates. Unity draws 8
`-` markers on the contrast zero line; the panel leaves them out, since Godot has
no equivalent decoration.

The Reveal slider emits `preview_changed` instead of `settings_changed`, because
it is a preview control: the shell writes the mesh material's `reveal` uniform,
so dragging it costs no pass. `Pick Color` asks the shell to arm colour sampling;
the map box preview forwards clicks as `preview_clicked` with the UV inside the
drawn image, and the shell reads that pixel from the working image. Materialize
raycasts the 3D test mesh for the same job; the box UV is the port's path.

Unity regenerates on every slider change; the Godot app does the same through the
debounce timer.

The module contract (`MapModules/map_module.gd`) is what keeps a panel from
touching shared state: a module exposes `map_type()`, `map_title()`,
`save_suffix()`, `settings()`, `panel_scene()`, `generate(source, blit)`,
`preview(map)`, `create_available(maps)`, `set_map()`, `clear_map()`, plus
`settings_changed` and `map_changed`. The shell owns the `Blit` node, the source
image, the map store, the panel slot, and the mesh. Clicking a box's `Create`
makes that map active: its panel is swapped into `UI/MapOptionsPanel/PanelSlot`,
its map goes onto the mesh, and the unported maps' `Create` buttons are disabled
with the status line naming the Unity file each one still needs.

## 5. Data space, and why gamma is dropped

Unity's render textures are `RenderTextureFormat.ARGB32` with
`RenderTextureReadWrite.Linear`, and the shaders take a `_GamaCorrection` value
(`pow(x, 2.2)` / `pow(x, 1/2.2)`) to move between sRGB-encoded and linear
values. The Godot port works entirely in the **raw file values** (the numbers
you see in the PNG), in float textures, with no gamma conversions anywhere. The
algorithms operate on 0..1 numbers and the "0.5 neutral" convention, which is
gamma-agnostic, so dropping `_GamaCorrection` changes the exact pixel values
(not the look) and removes a whole class of conversion bugs. Pixel-exact parity
with Unity was explicitly not a goal.

## 6. Skipped / deferred in this commit

- **"Use Normal as input"** for the height tool (Unity's `ProcessNormal()` and
  the Spread / SpreadBoost normal path, `_HeightFromNormal`). The Godot app has
  no normal map source yet; this returns when Normal From Height is ported.
- **Preview on a 3D mesh**: the map box previews and the `MeshInstance3D` show the
  live map. The mesh material (`shaders/mesh_preview.gdshader`) mixes the map
  towards mid-grey by the Height Reveal Slider and splits source / edited at the
  seam for the Diffuse Reveal Slider, so dragging either slider costs no pass. Materialize renders every map on a test object with the DNMST preview
  shader and cubemap lighting; the port applies one map at a time with a plain
  `shader_type spatial` material, so DNMST, the cubemap cycling (`next cube map`)
  and the FBX test meshes are still deferred.
- **Export formats**: Godot saves PNG, JPG, WebP. BMP / TIFF / TGA need a
  custom writer, so the saving box writes PNG and the status line says so. Unity
  used `FreeImage.dll` for those formats.
- **Project save/load** (Unity XML → `ConfigFile`/JSON): deferred.
- **Stock maps, cubemaps, FBX meshes, PSD icons**: not copied from the Unity
  repo. FBX cannot be imported by Godot (needs a `.glb` conversion), PSD icons
  need PNG conversion. A procedural stone test pattern (`core/test_pattern.gd`)
  stands in for a source image.

## 7. Files in the port

- `MapModules/map_module.gd` — the module contract, shared by every map module.
- `MapModules/heightMap/height_from_diffuse.gdshader` — passes 0 SAMPLE, 1 BLUR,
  2 COMBINE, 3 AVG; HSL sampling, raised-cosine separable blur, combine math.
- `MapModules/heightMap/height_from_diffuse.gd` — settings dict, presets, gain
  mapping, the generate coroutine (sample → pyramid → avg → combine).
- `MapModules/heightMap/height_panel.gd` + `height_panel.tscn` — the Height tool
  panel, laid out like `HeightFromDiffuseGui.cs`.
- `MapModules/heightMap/height_map_module.gd` — binds the generator and the panel
  to the module contract.
- `MapModules/diffuseMap/edit_diffuse.gdshader` — pass 1 BLUR (separable
  raised-cosine, Unity's pass 1, used twice: average map, then overlay), pass 2
  EDIT (`fragEditDiffuse`: light / shadow masks, spot removal, contrast, bias,
  keep, saturation).
- `MapModules/diffuseMap/edit_diffuse.gd` — settings dict with Materialize's
  defaults, the generate coroutine (average blur → average map → overlay blur →
  edit).
- `MapModules/diffuseMap/diffuse_panel.gd` + `diffuse_panel.tscn` — the Diffuse
  tool panel, laid out like `EditDiffuseGui.cs` in window order, including the
  split-screen reveal slider and "Set as Diffuse".
- `MapModules/diffuseMap/diffuse_map_module.gd` — binds the generator and the
  panel to the module contract, and adds the two preview hooks
  (`source_map_type()`, `preview_split()`).
- `core/blit.gd` — the pass framework (setup, blit, flat, format helpers).
- `core/test_pattern.gd` — procedural stone wall source (mortar, per-brick tone,
  bevel at joints, grain, top-down lighting gradient) so the average subtraction
  can be tested without loading a photo.
- `shaders/mesh_preview.gdshader` — the mesh preview material (`map` + `reveal` +
  `split_reveal` + `original`, the split-screen for the Diffuse Reveal Slider).
- `ui/map_box.gd` + `scenes/map_panel.tscn` — the generic map box (title,
  preview, `P` `C` `O` `S`, Quick Save, Preview, Create, Clear) and its
  `preview_clicked` UV forwarding.
- `scenes/main.tscn` + `scripts/main.gd` — the app shell: the box row, the panel
  slot, the mesh, the load / save / save-all dialogs, the port-only toolbar (load
  diffuse, stone pattern, resolution, generate, save, status), colour picking,
  the debounce timer, and the roadmap print.
- `scenes/save_panel.tscn` — the saving box (file format + `Save all maps!`).
- `tests/blit_probe.gd` + `tests/probe.gdshader` + `tests/blit_probe.tscn` —
  readback, HDR, repeat-wrap, blur-kernel probe.
- `tests/height_test.gd` + `tests/height_test.tscn` — end-to-end run on the stone
  pattern, writing PNGs and statistics.
- `tests/height_cpu.gd` + `tests/height_cpu.tscn` — CPU-only reference
  implementation of the whole pipeline (no GPU, no VRAM), used to validate the
  math and to provide a reference image for the GPU result.
- `tests/live_preview.gd` + `tests/live_preview.tscn` — drives the real app:
  checks the map on the mesh, the reveal uniform, the
  preset → debounce → pass chain → box preview chain, the map checksum, and saves
  a window screenshot.
- `tests/diffuse_cpu.gd` + `tests/diffuse_cpu.tscn` — CPU-only reference of
  `fragBlur` + `fragEditDiffuse` (no GPU, no VRAM), the kernel the GPU chain is
  measured against.
- `tests/diffuse_test.gd` + `tests/diffuse_test.tscn` — end-to-end 1024² chain on
  the stone pattern, writing PNGs and statistics.
- `tests/diffuse_live.gd` + `tests/diffuse_live.tscn` — drives the real app for
  Diffuse: panel swap, split-screen uniforms, generation from the pristine
  source, "Set as Diffuse", Clear restore.

## 8. Testing status

The GPU passes have been run on the user's machine (Vulkan 1.4.341, Forward Plus,
NVIDIA RTX 3080). What is verified:

- `godot --headless --path . --import`, `godot --path . --headless --quit`, and
  `godot --headless -e --path . --quit` run clean (scripts parse, scenes load, the
  Height panel and the Diffuse panel instantiate in `MapOptionsPanel` with every
  `@export` node reference resolving, and the roadmap prints with Diffuse marked
  ported). A
  headless run skips the pass chain, because the headless display server cannot
  render the `SubViewport` quad.
- **The algorithm itself, on the CPU.** `tests/height_cpu.tscn` is a pure
  GDScript reference implementation of all four stages — grey base, the
  raised-cosine separable pyramid, the wide average map, the combine. It uses
  no GPU, no VRAM, no shaders, so it validates the math on its own:

  ```
  godot --headless --quit --path . res://tests/height_cpu.tscn
  ```

  Results at 128² (about 100 s, `posmod` wrapping, linear taps matching
  `filter_linear + repeat_enable`):

  ```
  flat source   -> min 0.500 max 0.500 mean 0.500   neutral, as required
  stone source  -> min 0.210 max 0.702 mean 0.402
  stone result  -> min 0.401 max 0.634 mean 0.498   centred on neutral, no clipping
  mortar 0.487  brick centres 0.503                  joints read as recessed
  ```

  This is the test that found the missing `+ 0.5` per level described in Stage 4 —
  the bug that made the height map come out pure black in the app.
- **The framework, on the GPU** (`tests/blit_probe.tscn`): 8-bit and HDR readback
  are exact, `FORMAT_RGBAF` keeps values above 1.0 (`1.25, 0.625, 0.0`), repeat
  wrap samples the opposite edge, and the separable blur spreads the marker with
  the centre tap dominant.
- **The generator, on the GPU** (`tests/height_test.tscn`, 1024²):

  ```
  source: min 0.214 max 0.666 mean 0.433
  result: min 0.357 max 0.637 mean 0.498   format RGBAF, 1024 x 1024
  ```

  The mean matches the CPU reference exactly (0.498); min/max differ by about
  0.05, which is the CPU reference approximating the shader's edge-tap window
  fade. The stone result is centred on neutral with no clipping, so the average
  subtraction and the combine are working on the GPU.
- **The live app chain** (`tests/live_preview.tscn`, which instantiates the real
  `scenes/main.tscn`): the generated map lands on the `MeshInstance3D` material
  (1024×1024); the Height Reveal Slider writes `settings["reveal"]` and the mesh
  material's `reveal` uniform with no pass chain; the `Details` weight preset
  writes `settings["weights"] = [0.7, 0.4, 0.3, 0.5, 0.8, 0.9, 0.7]` and the fader
  values, fires the debounce, runs the pass chain, updates the map box preview,
  and moves the map checksum (0.251124 → 0.251701) — which is what proves the
  weight uniforms reached the shader. `user://live_preview_window.png` is a
  screenshot of the running app for eyeballing.
- **The Diffuse algorithm, on the CPU** (`tests/diffuse_cpu.tscn`, 64²): the CPU
  port of `fragBlur` + `fragEditDiffuse` matches the GPU chain pixel-for-pixel.
  Neutral settings (Materialize's defaults) give mean 0.499 on the CPU and 0.499
  on the GPU, max pixel delta 0.0004; strong settings (light mask 1, shadow mask
  1, remove light / shadow 1, contrast 2, bias 0.5, keep 0, saturation 0.2) give
  0.611 vs 0.612, max pixel delta 0.0005. The neutral chain is not an identity
  map: `Keep Original Color` 0.5 bakes the lighting removal, which is what
  Unity's default settings do.
- **The Diffuse generator, on the GPU** (`tests/diffuse_test.tscn`, 1024²):

  ```
  source: min 0.214 max 0.666 mean 0.433
  neutral: mean 0.511   strong: mean 0.599, moved +0.088
  ```

  The neutral mean sits inside the reference band centred on 0.5 (CPU 0.499) and
  the strong settings move the map. PNGs go to `user://diffuse_test/`.
- **The live Diffuse app chain** (`tests/diffuse_live.tscn`): activating the
  module swaps `DiffusePanel` into `MapOptionsPanel` (14 slider rows); the Diffuse
  Reveal Slider writes `settings["reveal"]` and the mesh material's
  `split_reveal` with no pass chain, and the `original` texture follows the
  source; generation sliders regenerate from `maps["diffuse_original"]` (edited
  mean 0.5004 vs source 0.4116); "Set as Diffuse" re-runs the chain; Clear
  restores the source to the box and to the split preview.

What is not verified: the visual result of the maps on the mesh (the screenshots
need a human eye), the exact stacked-blur tail Unity produces (see the stacking
note), and everything that depends on unported maps (Normal, Metallic,
Smoothness, Edge, AO, alignment, seamless tiling, DNMST preview, cubemap lighting,
project save, BMP/TIFF/TGA export).
