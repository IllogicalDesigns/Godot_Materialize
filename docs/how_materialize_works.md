# How Materialize works

Materialize (Unity Technologies, 2013, GPLv3) turns a single photograph into a
set of PBR texture maps: diffuse, height, normal, edge, ambient occlusion,
metallic, smoothness. It does this by running a chain of full-screen GPU shader
passes over the image, each pass writing into a render texture that feeds the
next pass. Every tool is a `.cs` GUI panel (Unity `OnGUI` sliders) plus one or
more `Blit_*.shader` fragment programs.

This document explains the algorithm as the Unity source does it, and how the
Godot port (`MapModules/`, `core/`, `shaders/`, `ui/`, `scenes/`) reproduces it.
The ported tools are Height From Diffuse, Edit Diffuse, Normal From Height,
Metallic From Diffuse and Roughness From Diffuse (Unity's Smoothness tool), each
in its own `MapModules/<map>Map/` folder; the same pattern applies to every tool.

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
blur, one horizontal and one vertical pass per radius (`EditDiffuseGui.cs` lines
417-432), and the port runs the same pair:

- **Overlay blur** (`Overlay Blur Size`, 5..100, default 20):
  `_BlurSamples` is the size and `_BlurSpread` is 1.0, so the taps step by one
  pixel across `±size`. `overlay = mainTex - blurTex` is the detail the tool
  re-amplifies. The port's window is the same `cos(i / radius * PI) * 0.5 + 0.5`
  over `±radius` taps.
- **Average colour** (`Average Color Blur Size`, 5..100, default 50): the wide
  blur, the lighting ramp `fragEditDiffuse` removes. The average stays in colour
  (Unity blurs the RGB map, not grey). Unity's deviation is here:
  `_BlurSpread` is `AvgColorBlurSize / 5` (line 432), so its taps are 10 pixels
  apart at the default 50 and the sampling span is far wider than the port's.
  The port carries the radius in the shader with spread 1.0, so its average map
  is the raised-cosine window at the slider size, a narrower span than Unity's
  spread-out taps. The CPU reference (`tests/diffuse_cpu.gd`) runs the same
  kernel the GPU runs, so the GPU-vs-CPU check measures the chain, not the
  spread difference.

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
(Height, Diffuse, Normal, Metallic, Smoothness, Edge, AO). The Smoothness box is
titled `Roughness Map`: the port stores the map as roughness, so the box name
follows the engine slot it fills (`StandardMaterial3D.roughness_texture`), and
the window's numbers are roughness too (`1 - smoothness`).

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

## 6. Normal From Height

Unity: `Scripts/NormalFromHeightGui.cs` (`ProcessHeight()` + `ProcessNormal()`),
with `Shaders/Resources/Blit_Shader.shader` (blur pass 1, normal pass 3, combine
pass 4). Godot: `MapModules/normalMap/normal_from_height.gd` +
`MapModules/normalMap/normal_from_height.gdshader`, passes 1, 3 and 4, mirroring
Unity's pass indices.

The core idea: **a normal map is the height map's slope, read at seven scales**.
The sobel gives the slope at pixel scale; each pyramid level is a coarser slope;
the Frequency Equalizer weights decide which scales survive. `Smooth` keeps the
broad scales and `Crisp` the sharp ones, so the same stone wall reads as rounded
relief or as crisp grit without touching the source.

Four stages:

### Stage 1 — light blur (pass 1, four passes)

The desaturated diffuse (when "Shape from Diffuse" is on) is blurred by the
Slope Blur window — 201 taps at spread 1, then spread 3, horizontal and vertical.
The result is the broad shape of the lighting: the reference the sobel normal is
blended towards by `Shape Recognition`. The blurs run at contrast 1.0;
`Pre Contrast` acts in the normal pass.

Godot shader loops need constant bounds, so the shader carries two kernels: the
201-tap `wide` window for the Slope Blur slider, and the 9-tap pyramid kernel
shared with the height tool.

### Stage 2 — normal from height (pass 3)

The sobel slopes of the height map:

```
slope_x = (1, 0, ddx * PreContrast)
slope_y = (0, 1, -ddy * PreContrast)
normal  = normalize(cross(slope_x, slope_y))
```

`Pre Contrast` is the slope strength. Godot's UV points down, so the vertical
slope is the negated screen slope; that keeps the normal pointing up out of a
flat surface, and a flat source stores `0.5, 0.5, 1.0` — the neutral normal map.

The shape term: `shape_height = (light - lightBlur + ShapeBias) * 2 - 1` is the
height the light reference carries. The light direction from `Light Rotation`
(-3.14..3.14, Unity's slider is already in radians) is tilted by that height, and
`dot(normal, cross(lightDir, (0,0,1))) * cross(lightDir, (0,0,1))` adds the slope
the light reference sees. `Shape Recognition` lerps the sobel normal towards the
shape; the result is stored signed, `normal * 0.5 + 0.5`, so 0.5 is neutral.

### Stage 3 — the normal pyramid (pass 1, twelve passes)

Six progressive separable blurs of the normal map, the same raised-cosine 9-tap
kernel as the height pyramid with the spread ladder
`1, 1 + e, 1 + 3e, 1 + 7e, 1 + 15e, 1 + 31e` where `e = avg(size) / 1024`.
`Desaturate` stays off: the RGB normals must survive, not collapse to grey.
Level 0 rides out as the pyramid's base, so seven scales go to the combine.

### Stage 4 — combine (pass 4)

The seven levels blend by the equalizer weights, divide by the weight sum (a
normal map has no grey to normalise against), decode back to a vector
(`* 2 - 1`) and normalise. `Angularity` pulls the normals towards the
`Angular Intensity` light direction — Materialize's trick for making relief read
as baked shading — `Final Contrast` multiplies xy and raises z to the same power,
then the vector is normalised once more and re-signed. Unity's combine ends with
`mainTex.y = 1 - mainTex.y` unless `_FlipNormalY` is set (Maya-style maps); the
port writes the Y the sobel computed, which is the OpenGL green that Godot and
the mesh preview read, so no flip is needed.

The Normal Reveal Slider blends the shaded preview towards the raw map colours in
`shaders/mesh_preview.gdshader` (`is_normal` mode), so dragging it costs no pass,
exactly as Materialize's `_Slider` in `Normal_From_Height_Preview.shader` works.

## 7. Metallic From Diffuse

Unity's `MetallicGui.cs` + `Assets/Shaders/Resources/Blit_Metallic.shader`.
The tool generates from the **diffuse map**, and the window's source row picks
which one: " Use Edited Diffuse" reads `_DiffuseMap`, " Use Original Diffuse"
reads `_DiffuseMapOriginal` (the pristine source), and Unity forces the pristine
source when no edited map exists (`MetallicGui.cs` lines 406-408). The port takes
the map store through `set_inputs(maps)` and keys the pristine source as
`maps["diffuse_original"]`, so the row selects inside the generator.

1. **blur** (`BlurSize`): one raised-cosine blur of the selected diffuse. The
   colour distance is measured on this blurred map, so the mask follows the
   region a pixel belongs to and survives noise. `BlurSize` 0 skips the blur and
   uses the sharp map (Unity copies the source into `_BlurMap` at 0,
   `MetallicGui.cs` lines 493-495).
2. **overlay blur** (`OverlayBlurSize`, 10..100): a second blur. Subtracting it
   from the sharp source leaves the high-frequency detail — the "High Pass
   Overlay" — so the mask follows the bumps and stops at joints.
3. **metallic** (`fragMetallic`, Blit_Metallic pass 0): the high pass overlay
   (`source - overlay_blur`, seen as grey), the colour distance from the picked
   metal colour measured on the blur map (`hue_dif` is the smallest of the three
   circular hue distances `* 2.0`, `sat_dif` and `lum_dif` are `1 - abs(diff)`),
   the weighted sum `hue_dif * Hue + sat_dif * Sat + lum_dif * Lum` divided by
   the weight total, `smoothstep(Low, High)`, then `Final Contrast` /
   `Final Bias`, then the mask is multiplied by
   `clamp(overlay_grey * BlurOverlay + 1, 0, 10)` and saturated. The output is
   a greyscale metallic mask in the red/green/blue channels.

Deviations: none in the pass structure — Unity runs one horizontal and one
vertical `fragBlur` pass per radius (`MetallicGui.cs` lines 479-514), and the
port runs the same pair with the same raised-cosine window
(`cos(i / radius * PI) * 0.5 + 0.5` over `±radius` taps). Unity divides the
colour distance by the raw weight sum; all three faders at 0 is a legal slider
state, so the port clamps the divisor.

The port: `MapModules/metallicMap/metallic_from_diffuse.gdshader` (PASS_BLUR /
PASS_METALLIC), `metallic_from_diffuse.gd` (the settings dict with
`MetallicSettings`' defaults, `MetallicGui.cs` lines 5-87: metal colour black,
Hue 1.0 / Sat 0.5 / Lum 0.2, Low 0.0 / High 1.0, BlurSize 0,
OverlayBlurSize 30, BlurOverlay 1, Contrast 1, Bias 0), `metallic_panel.tscn` +
`.gd` laid out like the Unity window, and `metallic_map_module.gd` (source key
`diffuse`, `preview_split()` true, because `Metallic_Preview.shader` lerps the
diffuse into the mask at `_Slider` along `UV.x`).

Verified: `tests/probe_hsl.tscn` runs the shader's `rgb_to_hsl` on the GPU and
the GDScript conversion on the CPU over the stone pattern — the two agree to
1e-3 — and `tests/metallic_cpu.tscn` mirrors the chain (stone mean 0.479, metal
mask 0.121, base mask 0.470, and the monotonicity checks on the overlay gain).

## 8. Roughness From Diffuse (Unity's Smoothness tool)

Unity's `SmoothnessGui.cs` + `Assets/Shaders/Resources/Blit_Smoothness.shader`.
The tool generates from the diffuse map (the same edited / pristine radio row
the Metallic window has) and from the **metallic map**. Pass 2
(`fragSmoothness`, lines 81-135) works in **smoothness space**: 1.0 is a mirror,
0.0 is fully rough.

1. **blur** (`BlurSize`): one raised-cosine blur of the selected diffuse, used
   for the sample masks. `BlurSize` 0 gives the sharp source, so `BlurSize`
   steers how large an area a colour sample covers.
2. **metal mask**: `_MetallicTex.x` — the metallic map — is the lerp weight that
   pulls the level to `MetalSmoothness`. Unity has **no** "Use Metal" toggle:
   pass 2 takes `_MetallicMap` when one exists and its `_DefaultMetallicMap`
   field otherwise, a field `SmoothnessGui.cs` never assigns (lines 680-684),
   so with no metallic map the weight is 0 and the chain never reaches
   `MetalSmoothness` — the map is base smoothness plus the sample masks. The
   port reads `maps["metallic"]` through `set_inputs(maps)` and substitutes a
   flat black map when the metallic map is missing or not the working
   resolution, the same effect as Unity's unassigned field.
3. **overlay**: the high pass grey (`source - overlay_blur`, seen as
   `GREY = vec3(0.3, 0.5, 0.2)`) drives `clamp(overlay_grey * BlurOverlay + 1,
   0, 10)`, which is applied to the level **after** the chain and the contrast /
   bias, as a multiplier (Unity line 126). `BlurOverlay` defaults to 3.0, so a
   strongly textured source can push the level up to 10x, saturating to a
   mirror.
4. **the smoothness chain**, in Unity's order (lines 120-123): start at
   `BaseSmoothness`, lerp towards `Sample2Smoothness` by `sample2Mask`, then
   towards `Sample1Smoothness` by `sample1Mask`, then towards `MetalSmoothness`
   by `metalMask`. Each sample's mask is the weighted colour similarity of the
   blur map against the swatch: `hue_dif` is the smallest of the three circular
   hue distances `* 2.0`, `sat_dif` and `lum_dif` are `1 - abs(diff)`, the three
   are weighted by `Hue` / `Sat` / `Lum`, divided by the weight total (Unity
   divides by the raw sum; all three faders at 0 is a legal slider state, so the
   port clamps the divisor), then `smoothstep(Low, High)`. `Isolate Mask` paints
   the mask itself as the level — Unity's lines 129-135, `finalSmoothness =
   sampleNMask`.
5. **the map**: Unity writes smoothness, so a preview at 1.0 reads as a mirror.

The port stores **roughness** = `1 - smoothness`, so every Unity number in the
window is inverted: MetalSmoothness 0.7 → `metal_roughness` 0.3,
BaseSmoothness 0.1 → `base_roughness` 0.9, Sample1Smoothness 0.5 → 0.5,
Sample2Smoothness 0.3 → `sample2_roughness` 0.7, and the final write is
`COLOR = 1 - final_smoothness`. The point is that the map drops straight into
Godot's PBR material: "Show full Material" fills
`StandardMaterial3D.roughness_texture` and sets
`roughness_texture_channel = TEXTURE_CHANNEL_RED`, because Unity's DNMST preview
reads its smoothness texture from the red channel (`DNMST.shader` line 121,
`tex2D(_SmoothnessMap, UV).x`). The Metallic slot is not wired yet; when it is,
`metallic_texture` + `METALLIC_TEXTURE_ALBEDO_CHANNEL_A` is the slot the port
will use.

Two structural differences from the Unity window, both deliberate:
- The GUI shows **3** colour samples; pass 2 uses **2**. The port ships 2, so
  there is no dead third control, and the faders read
  faders read `Hue` / `Sat` / `Lum` / `Low` / `High` / `Rough` (Unity's
  `SampleNSmoothness` slider, with the inverted value).
- Unity has **no** "Use Metal" toggle: the metallic map alone decides how much
  metal shows. The port matches, and the Metallic module's presence is the
  switch — with no metallic map, Unity's flat black `_DefaultMetallicMap`
  behaviour is the flat black fallback.

The port: `MapModules/roughnessMap/roughness_from_diffuse.gdshader` (PASS_BLUR /
PASS_ROUGHNESS, the same `GREY = vec3(0.3, 0.5, 0.2)` and `rgb_to_hsl` the
Metallic pass uses), `roughness_from_diffuse.gd` (the settings dict, inverted
defaults, the generate coroutine: radio row source → blur → overlay → smoothness
chain → invert), `roughness_panel.tscn` + `.gd` laid out like `SmoothnessGui.cs`
in Unity's window order: the source radio row, the Roughness Reveal Slider,
Metal Roughness, the two foldable colour samples (Use / Isolate / Pick Colour
and the Hue / Sat / Lum / Low / High / Rough faders, Base Roughness last among
the level rows), Blur Size, Overlay Blur Size, High Pass Overlay, Final
Contrast, Final Bias, "Set as Roughness". The sample bodies are
`CollapseGroup`s, so a sample folds when its Use box goes off, as the Height
panel does. `roughness_map_module.gd` gives `map_type()` "roughness", the
`_RoughnessMap` save suffix, `set_inputs` reading `maps["metallic"]`, and
`preview_split()` true.

Verified: `tests/roughness_cpu.tscn` mirrors the chain (the GPU-CPU chain delta
on the stone pattern is 0.0148; stone mean 0.600 stored as roughness, 0.400 as
smoothness; mask edges, overlay monotonicity, the blur size effect, and the
metallic coupling all behave as Unity's pass 2 does), and
`tests/roughness_live.tscn` drives the panel through the shell: stone mean
0.312, a brick sample (red / 100% saturation / 50% roughness, 0.4 saturation
window) pulls its pixels to 0.677, the Full Material's Roughness slot and red
channel fill, "Set as Roughness" re-runs, Clear empties the map, and the Reveal
Slider moves only the seam.

## 9. AO From Normal (Materialize's Normal + Depth to AO tool)

Unity's `AOFromNormalGui.cs` + `Assets/Shaders/Resources/Blit_Shader.shader`
pass 7 (`fragAO`, lines 344-415) and pass 8 (`fragCombineAO`, lines 417-432),
the pair `ProcessNormalDepth()` + `ProcessAO()` run (lines 289-338, 256-287).
The window is "Normal + Depth to AO", 300 x 280 px, and the tool is the one
that does **not** read the diffuse: the pass reads the **Normal map** as its
source (`_MainTex`, the AO blit line 323 blits `_NormalMap` straight) and the
**Height map** for its depth term (`_HeightTex`; `InitializeTextures` prefers
`_HDHeightMap` over `_HeightMap`, lines 304-310).

The window, top to bottom (`AOFromNormalGui.cs` lines 173-190, `AOSettings`
defaults lines 35-53):

1. **AO pixel Spread** (10..100, default 50): the ray length in pixels.
2. **Pixel Depth** (0..256, default 100): how steep a height step counts.
3. **Blend Normal AO and Depth AO** (0..1, default 1): how much of the depth AO
   shows. Unity opens the window with 1 when a height map exists and 0 when it
   does not (`InitializeSettings`, lines 108-114), because its flat default
   height reads fully occluded, so the depth term has nothing to contribute.
4. **AO Power** (0.1..10, default 1) and **AO Bias** (-1..1, default 0): the
   final grade. Unity applies the grade to the preview material every frame
   while dragging (lines 159-161) and bakes it in pass 8 at Set time.

Unity has **no** reveal slider in this window, so the AO panel has no
`preview_changed` signal and the mesh preview is the map plain.

**The accumulation.** Unity runs pass 7 99 times (`for( int i = 1; i < 100;
i++ )`, line 318) with `progress = i / 100` and `blend_amount = 1 / i`. The
pass sweeps the ray direction a full circle over the 99 passes, and each pass
casts 50 samples along the ray (`int AOSamples = 50`, fragAO line 361):

- sample `p = i / 50` (Unity's sample index divided by the count), the sample
  offset `direction * Spread * p` plus a two-channel hash jitter scaled by `p *
  0.1`, the sample pixel `uv + pixelSize * offset` (fragAO lines 378-382),
- the **normal term**: `dot(normal_sample, direction) * sqrt(1 - p)`, the
  weighted mean over the samples — the ray tilting back towards the surface is
  the occlusion the normal map reads, and the far samples matter least,
- the **depth term**: the sample position in 3D,
  `(direction.xy * Spread * p, (sample_height - main_height) * Depth)`, its
  `dot` with straight-up, the strongest occlusion wins the pass, `saturate`d
  against the distance,
- the pass lerps its AO.x / AO.y into the blend texture (`_BlendTex`) at
  `1 / i`, so the accumulator ends up a running mean of ~100 directions, and
  AO.y is written inverted (`1 - occlusion`), the light side.

Pass 8 lerps the two AO channels at **Blend**, adds **Bias**, raises to the
power of **Power**, saturates.

**The port.** `MapModules/aoMap/ao_from_normal.gdshader` (PASS_AO = 1,
PASS_COMBINE = 2, the pair mirroring Unity's pass 7 / pass 8) with
`ao_from_normal.gd` as the driver: the 99-pass accumulation loop, the blend /
power / bias combine, the settings dict with `AOSettings`' defaults, and the
flat normal / flat height fallbacks Unity's `InitializeTextures` opens with
(`defaultNormal` is flat_normal.tga, the port's `Color(0.5, 0.5, 1.0)`;
`defaultHeight` is flat_grey.tga, the port's `Blit.flat(size, 0.5)`). Unity
ping-pongs the accumulator through a copy blit (lines 323-324); the port keeps
one `Image` and feeds it back as the `accumulator` sampler, the same
accumulation with one pass per iteration.

**UV mirroring, the frame conversion the port needs:** Godot's UV points down,
Unity's up, so the ray direction, the sample offsets, and the stored normal's
Y component are all negated. Unity's default `_FlipNormalY == 0` mirror (fragAO
lines 350-353) becomes this conversion, so the port reads its signed normal raw.

**Deviations, all deliberate:**
- Unity enables the box's Create with a Normal map **or** a Height map (line
  1034); the port gates Create on the **Normal map alone**: the shell runs every
  tool from its `source_map_type()` map, so a height-only Create has no source
  map to run from.
- Unity applies AO Power, AO Bias and the blend to the preview material every
  frame while dragging and bakes them only at Set time; the port bakes the grade
  inside pass 2, so the shell's debounce re-runs the combine pass on every
  settle, the way the Metallic panel behaves.
- `pow()` of a negative base is undefined in GLSL, so the port clamps to 0
  before the power (Unity's bias can push the value negative).
- Unity seeds the ray jitter from `_Time.y` (fragAO line 362), a per-frame clock
  Godot has no equivalent of; the start offset is computed and never read by the
  pass, so the port drops it.
- Unity prefers `_HDHeightMap` over `_HeightMap`; the port has one height map,
  so that map is the depth input.
- The ray hash decorrelates between the CPU and the GPU (the GPU's `sin`
  argument reduction at ~23000 differs from `sin` on CPU doubles), so the
  CPU reference compares **aggregate stats**, not per-pixel values: the mean,
  the spread, and the groove-vs-plate column ordering.

**The panel:** `MapModules/aoMap/ao_panel.gd` + `ao_panel.tscn`, laid out like
Unity's window: the title "Normal + Depth to AO", the five rows (AO pixel
Spread, Pixel Depth, Blend Normal AO and Depth AO, AO Power, AO Bias), and
"Set as AO Map". Every widget is an `@export` assigned in the Inspector.
`ao_map_module.gd` gives `map_type()` "ao", `map_title()` "AO Map", the
`_ao` save suffix, `source_map_type()` "normal", `set_inputs(maps)` reading
`maps["height"]` for the depth term, and `create_available(maps)` on the normal
map.

**The full material's AO slot:** "Show full Material" fills
`StandardMaterial3D.ao_texture` + `ao_texture_channel = TEXTURE_CHANNEL_RED`
and switches the feature flag `ao_enabled` on with the map, off when the map
is cleared — the engine probe (`tests/ao_probe.tscn`) reports the properties
this engine version has (`ao_enabled`, `ao_light_affect`, `ao_texture`,
`ao_on_uv2`, `ao_texture_channel`). Unity's AO preview
(`AO_From_Normal_Preview.shader`) multiplies the AO map into the lit colour on
the test object, which is what the engine's AO slot does.

Verified: `tests/ao_cpu.tscn` mirrors the cone sweep on the stone wall (32 px,
12 passes, 6 samples): gpu mean 0.724 vs cpu 0.725, std 0.171 on both, the
groove column (mortar line) is darker than the plate column on both sides
(0.676 gpu / 0.669 cpu vs 0.682 / 0.688), blend off raises the mean to 0.859
gpu / 0.855 cpu, AO Power 5 pushes it to 0.313 / 0.315, AO Bias 0.3 lifts it to
0.937 / 0.938 — the combine pass agrees to 0.002. `tests/ao_probe.tscn` sweeps
the cone model at 16 px: blend on gives spread 50 → 0.627, 100 → 0.708, 10 →
0.671 (the mean rises with spread at 16 px, the cone wraps the tile), blend off
gives 0.876 / 0.885 / 0.707, so the AO.x curve sits at 0.876 on the flat plate.
`tests/ao_live.tscn` drives the panels through the shell at 512 px: the wall
opens at mean 0.817, Spread 100 changes the map (0.813 — the mean's direction
is resolution-dependent, the fixed part is that the slider moves the map),
blend off raises the mean to 0.856, AO Power and Bias re-run the combine pass,
"Set as AO Map" and Clear cycle the box, the groove column (0.751) is darker
than the plate column (0.753), and the AO map fills the Full Material's AO slot
through the red channel — all PASS, 1219 frames.

## 10. Skipped / deferred in this commit

- **"Use Normal as input"** for the height tool (Unity's `ProcessNormal()` and
  the Spread / SpreadBoost normal path, `_HeightFromNormal`). Normal From Height
  is ported, so a normal map now exists in the app, but the height generator
  still reads only the diffuse source; wiring its normal-input path is the next
  step, and Unity's `_HeightFromNormal` shader path is the reference for it.
- **Preview on a 3D mesh**: the map box previews and the `MeshInstance3D` show the
  live map. The mesh material (`shaders/mesh_preview.gdshader`) mixes the map
  towards mid-grey by the Height Reveal Slider and splits source / edited at the
  seam for the Diffuse Reveal Slider, so dragging either slider costs no pass. Materialize renders every map on a test object with the DNMST preview
  shader and cubemap lighting; the port applies one map at a time with a plain
  `shader_type spatial` material, so DNMST, the cubemap cycling (`next cube map`)
  and the FBX test meshes are still deferred. "Show full Material" fills five
  `StandardMaterial3D` slots (Albedo, Normal, Heightmap, Roughness, AO); the Metallic
  slot (`metallic_texture` + `METALLIC_TEXTURE_ALBEDO_CHANNEL_A`) is the next one
  to wire, and `tests/full_live.tscn` grows its assertion when it is.
- **Export formats**: Godot saves PNG, JPG, WebP. BMP / TIFF / TGA need a
  custom writer, so the saving box writes PNG and the status line says so. Unity
  used `FreeImage.dll` for those formats.
- **Project save/load** (Unity XML → `ConfigFile`/JSON): deferred.
- **Stock maps, cubemaps, FBX meshes, PSD icons**: not copied from the Unity
  repo. FBX cannot be imported by Godot (needs a `.glb` conversion), PSD icons
  need PNG conversion. A procedural stone test pattern (`core/test_pattern.gd`)
  stands in for a source image.

## 11. Files in the port

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
- `MapModules/normalMap/normal_from_height.gdshader` — pass 1 BLUR (the two
  kernels: 201-tap `wide` window for Slope Blur, 9-tap pyramid kernel), pass 3
  NORMAL (sobel + `Shape Recognition` shape term), pass 4 COMBINE (equalizer
  weights, angularity, final contrast).
- `MapModules/normalMap/normal_from_height.gd` — settings dict with Materialize's
  defaults, the four presets' weight rows, and the generate coroutine (light blur
  → normal → six pyramid levels → combine).
- `MapModules/normalMap/normal_panel.gd` + `normal_panel.tscn` — the Normal tool
  panel, laid out like `NormalFromHeightGui.cs` in window order: Normal Reveal
  Slider, Pre Contrast, the 7-fader Frequency Equalizer with Default / Smooth /
  Crisp / Mids, Angular Intensity, Angularity, Shape from Diffuse, Shape
  Recognition, Light Rotation, Slope Blur, Shape Bias, Final Contrast, "Set as
  Normal Map".
- `MapModules/normalMap/normal_map_module.gd` — binds the generator and the panel
  to the module contract, reads the height map as its source, and takes the map
  store through `set_inputs` for "Shape from Diffuse".
- `MapModules/metallicMap/metallic_from_diffuse.gdshader` — pass 1 BLUR
  (raised-cosine, used twice: the comparison blur, then the overlay blur), pass 2
  METALLIC (`fragMetallic`: hue / sat / lum distance from the metal colour,
  smoothstep mask, high pass overlay, contrast, bias).
- `MapModules/metallicMap/metallic_from_diffuse.gd` — settings dict with
  Materialize's defaults, the generate coroutine (blur → overlay blur →
  fragMetallic), the edited / pristine source row.
- `MapModules/metallicMap/metallic_panel.gd` + `metallic_panel.tscn` — the
  Metallic tool panel, laid out like `MetallicGui.cs` in window order: the source
  radio row, the Metalic Reveal Slider, the Metal Colour swatch + Pick Colour,
  the Hue / Sat / Lum / Low / High faders, Blur Size, Overlay Blur Size, High
  Pass Overlay, Final Contrast, Final Bias, "Set as Metallic".
- `MapModules/metallicMap/metallic_map_module.gd` — binds the generator and the
  panel, takes the map store through `set_inputs` for " Use Original Diffuse",
  and splits the mesh preview like Unity's `Metallic_Preview.shader`.
- `MapModules/roughnessMap/roughness_from_diffuse.gdshader` — pass 1 BLUR,
  pass 2 ROUGHNESS (`fragSmoothness`: the smoothness chain in smoothness space,
  the metallic-driven overlay, the isolate override, and the `1 - smoothness`
  write).
- `MapModules/roughnessMap/roughness_from_diffuse.gd` — settings dict with the
  inverted defaults, the generate coroutine (source row → blur → overlay →
  smoothness chain), the metallic coupling through the map store.
- `MapModules/roughnessMap/roughness_panel.gd` + `roughness_panel.tscn` — the
  Roughness tool panel, laid out like `SmoothnessGui.cs`: Roughness Reveal
  Slider, source row, Metal Roughness, Base Roughness, two foldable colour
  samples (Use / Isolate / Pick Colour / Hue / Sat / Lum / Low / High /
  Roughness), Blur Size, Overlay Blur Size, High Pass Overlay, Final Contrast,
  Final Bias, "Set as Roughness".
- `MapModules/roughnessMap/roughness_map_module.gd` — binds the generator and
  the panel, `set_inputs` reads `maps["metallic"]` the way Unity's
  `_MetallicTex` does, and the split preview follows the Reveal Slider.
- `_fill_full_material()` in `scripts/main.gd` — "Show full Material" fills one
  exported `StandardMaterial3D` (`_full_material`) from the map store: Albedo
  (`albedo_texture`), Normal (`normal_texture`), Heightmap
  (`heightmap_texture`), Roughness (`roughness_texture` +
  `TEXTURE_CHANNEL_RED`), and AO (`ao_texture` + `TEXTURE_CHANNEL_RED`, with
  the `ao_enabled` flag on with the map and off when it is cleared). The
  Metallic slot is not filled yet. The Full Material
  is not a map in the store, so the shell keys the mesh's full-material mode
  with its own `FULL_MESH_MAP` value.
- `tests/probe_hsl.gd` + `tests/probe_hsl.gdshader` + `tests/probe_hsl.tscn` —
  the GPU `rgb_to_hsl` probe: the shader's HSL conversion measured against the
  GDScript conversion over the stone pattern.
- `tests/probe_main.gd` + `tests/probe_main.gdshader` + `tests/probe_main.tscn`
  — the canvas_item repeat-wrap check (`repeat_enable` on a `SCREEN_UV`
  canvas_item shader), the assumption the sample masks' 1.0 wrap rides on.
- `tests/metallic_cpu.gd` + `tests/metallic_cpu.tscn` — CPU-only mirror of the
  Metallic chain (both blurs + `fragMetallic`), the panel checks, and the
  statistics the GPU run is measured against.
- `tests/full_live.gd` + `tests/full_live.tscn` — drives "Show full Material":
  the Full Material's albedo, metallic, and roughness slots, the split source,
  and the reveal seam.
- `tests/roughness_cpu.gd` + `tests/roughness_cpu.tscn` — CPU-only mirror of the
  Roughness chain (blur + the smoothness pass + the invert), the mask-edge and
  overlay-monotonicity checks, the metallic coupling checks, and the panel checks.
- `tests/roughness_live.gd` + `tests/roughness_live.tscn` — drives the real app
  for Roughness: the stone map, the brick colour sample, the Full Material's
  Roughness slot and red channel, "Set as Roughness", Clear, and the Reveal
  Slider seam.
- `tests/roughness_probe.gd` + `tests/roughness_probe.tscn` — probe of
  `StandardMaterial3D`'s roughness properties: the port fills
  `roughness_texture` + `TEXTURE_CHANNEL_RED` and nothing else, because
  `roughness_enabled` / `ROUGHNESS_MODE_TEXTURE` do not exist in this version of
  Godot.
- `MapModules/aoMap/ao_from_normal.gdshader` — pass 1 AO (`fragAO`: the 50-sample
  ray per pass, the normal term and the depth term, the running mean into the
  accumulator), pass 2 COMBINE (`fragCombineAO`: blend, bias, power, saturate).
- `MapModules/aoMap/ao_from_normal.gd` — settings dict with `AOSettings`'
  defaults, the generate coroutine (the accumulation loop, pass 1..99, then the
  combine pass), and the flat normal / flat height fallbacks.
- `MapModules/aoMap/ao_panel.gd` + `ao_panel.tscn` — the AO tool panel, laid out
  like `AOFromNormalGui.cs` in window order: AO pixel Spread, Pixel Depth, Blend
  Normal AO and Depth AO, AO Power, AO Bias, "Set as AO Map".
- `MapModules/aoMap/ao_map_module.gd` — binds the driver and the panel, reads the
  normal map as its source (`source_map_type()` "normal"), and takes the map
  store through `set_inputs` for the height map's depth term.
- `tests/ao_cpu.gd` + `tests/ao_cpu.tscn` — CPU mirror of the AO chain (the
  accumulation passes + the combine pass), the aggregate stats the GPU run is
  measured against, and the blend / contrast / bias checks on both sides.
- `tests/ao_live.gd` + `tests/ao_live.tscn` — drives the real app for AO: the
  height, normal and AO chains, the panel bindings, the spread / blend / power /
  bias slider effects through the debounce, "Set as AO Map", the Full Material's
  AO slot, and Clear.
- `tests/ao_probe.gd` + `tests/ao_probe.tscn` — probe of `StandardMaterial3D`'s
  AO properties: `ao_enabled` + `ao_texture` + `ao_texture_channel`, the feature
  flag the AO slot needs.
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
- `tests/normal_cpu.gd` + `tests/normal_cpu.tscn` — CPU-only mirror of the whole
  Normal pass chain (light blur, sobel normal, six pyramid levels, combine) on the
  stone test pattern at the shell's 512 resolution; prints the statistics the
  live test asserts and writes `user://normal_cpu/*.png`.
- `tests/normal_live.gd` + `tests/normal_live.tscn` — drives the real app for
  Normal: resolution switch, panel wiring, the Slope Blur / Final Contrast /
  Shape Bias sliders, the Smooth and Crisp presets, "Set as Normal Map", and the
  Normal Reveal Slider on the mesh preview; asserts the GPU map matches the CPU
  reference.

## 12. Testing status

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

- **The Metallic chain, on the CPU and the GPU** (`tests/metallic_cpu.tscn`,
  256²): the CPU mirror of both blurs + `fragMetallic` gives stone mean 0.479
  with metal mask 0.121 and base mask 0.470, the overlay gain moves the mask
  monotonically, and the panel's defaults and bindings resolve in the shell. The
  GPU's `rgb_to_hsl` is measured against the CPU conversion by
  `tests/probe_hsl.tscn` (agreement to 1e-3). `tests/full_live.tscn` runs "Show
  full Material" and asserts the Albedo, Normal, and Heightmap slots;
  `tests/roughness_live.tscn` asserts the Roughness slot and its red channel;
  `tests/ao_live.tscn` asserts the AO slot (the `ao_enabled` flag, the map, and
  its red channel) and the cone-sweep checks on the spread / blend / power / bias
  sliders.
- **The Roughness chain, on the CPU** (`tests/roughness_cpu.tscn`, 256²): the
  CPU mirror gives stone mean 0.600 stored as roughness (0.400 as smoothness),
  base roughness 0.9 writes 0.9, `BlurSize` 20 smooths the sample masks
  (sample mean 0.330 → 0.211), the overlay gain raises the map monotonically,
  clearing the metallic map takes the chain to base, and the isolate override
  writes the mask. The measured GPU-CPU chain delta is 0.0148.
- **The live Roughness app chain** (`tests/roughness_live.tscn`, 512²): the
  Metallic window runs first on the wall's own brick colour (hue 1.0, Low 0.0 /
  High 0.5), giving a metallic map with mean 0.969 — the wall scores as metal.
  The Roughness box's Create then runs its passes on the diffuse: the map mean
  drops to 0.312, far below Base Roughness 0.9, because the metal lerp pulls the
  level to Metal Roughness 0.3, and the map carries the metallic map's detail
  (spread 0.1686). "Show full Material" fills the Full Material's Roughness slot
  with the map, read from the red channel, at the map's size; the Reveal Slider
  at 0.3 writes `reveal` / `split_reveal` and the label with no pass chain;
  clearing the Metallic map and setting Base Roughness 0.2 moves the mean to
  0.202, which is the base level reading straight; "Set as Roughness" re-runs
  the chain, and Clear empties the map. The panel's defaults, every widget
  binding, the isolate rows, and the source radio all check out.
- **The AO chain, on the CPU and the GPU** (`tests/ao_cpu.tscn`, 32², 12 passes,
  6 samples): the CPU mirror of the cone sweep agrees with the GPU on the
  aggregate stats — mean 0.724 gpu vs 0.725 cpu, std 0.171 on both; the mortar
  groove column is darker than the brick-face plate column on both sides
  (0.676 / 0.669 vs 0.682 / 0.688); blend off raises the mean to 0.859 gpu /
  0.855 cpu; AO Power 5 pushes it to 0.313 / 0.315 and AO Bias 0.3 lifts it to
  0.937 / 0.938, so the combine pass agrees to 0.002. `tests/ao_probe.tscn`
  sweeps the cone model at 16 px: blend on gives spread 50 → 0.627, 100 → 0.708,
  10 → 0.671; blend off gives 0.876 / 0.885 / 0.707, so the AO.x curve sits at
  0.876 on the flat plate. `tests/ao_live.tscn` drives the real app at 512 px
  with the full 100 passes: the wall opens at mean 0.817, Spread 100 changes the
  map (0.813), blend off raises the mean to 0.856, AO Power and Bias re-run the
  combine pass, "Set as AO Map" and Clear cycle the box, the groove column
  (0.751) is darker than the plate column (0.753), and the AO map fills the Full
  Material's AO slot through the red channel, 1219 frames.

What is not verified: the visual result of the maps on the mesh (the screenshots
need a human eye), the exact stacked-blur tail Unity produces (see the stacking
note), and everything that depends on unported maps (Edge, alignment,
seamless tiling, DNMST preview, cubemap lighting, project save, BMP/TIFF/TGA
export), plus the height tool's "Use Normal as input" path, which the ported
normal map now makes possible. The ported Metallic, Roughness and AO chains are
measured against CPU mirrors and the live app, not against a render from the
Unity tool, so the numbers are the port's own.
