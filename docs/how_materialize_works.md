# How Materialize works

Materialize (Unity Technologies, 2013, GPLv3) turns a single photograph into a
set of PBR texture maps: diffuse, height, normal, edge, ambient occlusion,
metallic, smoothness. It does this by running a chain of full-screen GPU shader
passes over the image, each pass writing into a render texture that feeds the
next pass. Every tool is a `.cs` GUI panel (Unity `OnGUI` sliders) plus one or
more `Blit_*.shader` fragment programs.

This document explains the algorithm as the Unity source does it, and how the
Godot port (`core/`, `shaders/`, `ui/`) reproduces it. The first ported tool is
Height From Diffuse; the same pattern applies to every other tool.

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
Godot: `core/height_from_diffuse.gd` + `shaders/height_from_diffuse.gdshader`,
passes 0..3.

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
gamma-lifted, scaled by that level's contrast, and weighted:

```
contribution[i] = (pow(level[i], 0.45) - pow(avg, 0.45)) * contrast[i] * weight[i]
height = sum(contribution) / sum(weight)
```

Two details carry the whole look:

- `pow(x, 0.45)` lifts midtones so fine detail survives in dark areas. With a
  plain subtraction, a dark brick's grain is smaller than the noise floor of
  the average; the lift makes it visible.
- Subtracting `pow(avg, 0.45)` kills the lighting gradient: what remains is
  relief at the scale of each level.

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

## 3. UI (Unity OnGUI → Godot Control)

`ui/height_panel.tscn` is a hand-authored panel: level weight sliders (0..2),
level contrast sliders (-4..4), Output contrast/bias/gain, preset buttons, and
two sample sections (Use / Isolate checkboxes, Pick button, compact
`ColorPicker` swatch, hue/sat/lum weights, mask low/high, sample height, plus
the shared SampleBlend slider). The panel edits the `HeightFromDiffuse.settings`
`Dictionary` in place and emits `settings_changed`; the main scene debounces a
`Timer` and regenerates. `Pick` asks the main scene to arm colour picking, then
a click on the source preview reads the pixel from the working `Image` and
feeds the sample colour.

Unity regenerates on every slider change; the Godot app does the same through
the debounce timer.

## 4. Data space, and why gamma is dropped

Unity's render textures are `RenderTextureFormat.ARGB32` with
`RenderTextureReadWrite.Linear`, and the shaders take a `_GamaCorrection` value
(`pow(x, 2.2)` / `pow(x, 1/2.2)`) to move between sRGB-encoded and linear
values. The Godot port works entirely in the **raw file values** (the numbers
you see in the PNG), in float textures, with no gamma conversions anywhere. The
algorithms operate on 0..1 numbers and the "0.5 neutral" convention, which is
gamma-agnostic, so dropping `_GamaCorrection` changes the exact pixel values
(not the look) and removes a whole class of conversion bugs. Pixel-exact parity
with Unity was explicitly not a goal.

## 5. Skipped / deferred in this commit

- **"Use Normal as input"** for the height tool (Unity's `ProcessNormal()` and
  the Spread / SpreadBoost normal path, `_HeightFromNormal`). The Godot app has
  no normal map source yet; this returns when Normal From Height is ported.
- **Preview on a 3D mesh**: Materialize renders the maps on a test object with
  the DNMST preview shader. The Godot preview is two flat `TextureRect`s
  (source, result); DNMST comes later.
- **Export formats**: Godot saves PNG, JPG, WebP. BMP / TIFF / TGA need a
  custom writer; deferred.
- **Project save/load** (Unity XML → `ConfigFile`/JSON): deferred.
- **Stock maps, cubemaps, FBX meshes, PSD icons**: not copied from the Unity
  repo. FBX cannot be imported by Godot (needs a `.glb` conversion), PSD icons
  need PNG conversion. A procedural stone test pattern (`core/test_pattern.gd`)
  stands in for a source image.

## 6. Files in this commit

- `core/blit.gd` — the pass framework (setup, blit, blit chain, flat, format
  helpers).
- `shaders/height_from_diffuse.gdshader` — passes 0 SAMPLE, 1 BLUR, 2 COMBINE,
  3 AVG; HSL sampling, raised-cosine separable blur, combine math.
- `core/height_from_diffuse.gd` — settings dict, presets, gain mapping, the
  generate coroutine (sample → pyramid → avg → combine).
- `core/test_pattern.gd` — procedural stone wall source (mortar, per-brick
  tone, bevel at joints, grain, top-down lighting gradient) so the average
  subtraction can be tested without loading a photo.
- `ui/height_panel.gd` + `ui/height_panel.tscn` — the control panel.
- `scripts/main.gd` + `scenes/main.tscn` — toolbar (load, test pattern,
  resolution 512/1024/2048/source, generate, save), source/result previews,
  colour picking, debounce timer, the tool roadmap.
- `tests/blit_probe.gd` + `tests/probe.gdshader` + `tests/blit_probe.tscn` —
  readback, HDR, repeat-wrap, blur-kernel probe.
- `tests/height_test.gd` + `tests/height_test.tscn` — end-to-end run on the
  stone pattern, writing PNGs and statistics.

## 7. Testing status

The user's machine has no VRAM headroom, so **no GPU pass has been executed
yet**. What is verified: `godot --headless --import --path .` and
`godot --headless --quit --path .` run clean (scripts parse, scenes load, the
panel syncs, the roadmap prints). What is not verified: shader compilation,
HDR readback, repeat wrap, blur tap behaviour, and the visual result.

Run these when VRAM has headroom, in this order:

```
DISPLAY=:1 godot --path . res://tests/blit_probe.tscn    # framework probe
DISPLAY=:1 godot --path . res://tests/height_test.tscn   # end-to-end, writes user://height_test/*.png
godot --path .                                          # the app
```

The probe prints expected values for each pass; the height test prints source
and result statistics (min / max / mean) so a broken pass shows up as a flat
mean, a mean pinned at 0.5, or NaN. In the app, the stone pattern plus default
settings should show joints as raised lines with a grainy brick surface, and
the top-down lighting gradient should be gone.
