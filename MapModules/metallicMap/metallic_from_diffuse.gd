class_name MetallicFromDiffuse
extends RefCounted
## Metallic Map - Materialize's Metallic tool, the pass driver.
##
## This is what Materialize runs in `ProcessBlur()` + `ProcessMetallic()`
## (`Assets/Scripts/MetallicGui.cs`), driven pass by pass through the `Blit`
## framework:
##
##   1. BLUR     - a separable raised-cosine blur at "Blur Size". This is the
##                 softened colour the mask is measured on, so a hue / sat / lum
##                 distance ignores the grain of the source.
##   2. OVERLAY  - a separable blur at "Overlay Blur Size". Subtracting it from
##                 the sharp source leaves the high-frequency detail, which the
##                 "High Pass Overlay" slider adds back into the mask, so the
##                 mask follows the bumps of the surface.
##   3. METALLIC - fragMetallic: colour distance from the picked metal colour
##                 (Hue / Sat / Lum weights), the Low / High smoothstep mask,
##                 the high pass overlay, final contrast, and final bias. The
##                 output is a greyscale metallic mask.
##
## Why the mask reads the blurred colour: a metal region is identified by the
## colour its pixels tend to, not by each pixel. Blurring first makes the
## comparison survive noise, then the high pass overlay puts the sharp edges
## back so the mask stops at brick joints and seams.
##
## The source is picked by the window's two toggles: " Use Edited Diffuse" reads
## `_DiffuseMap`, " Use Original Diffuse" reads `_DiffuseMapOriginal`. The shell
## owns both map keys, so it hands the pristine source in beside the pass
## source, the same way "Shape from Diffuse" works in Normal From Height.

const SHADER_PATH := "res://MapModules/metallicMap/metallic_from_diffuse.gdshader"

## The shader passes, mirroring the Unity SubShader pass indices
## (Blit_Shader blur pass 1, Blit_Metallic metallic pass 0).
const PASS_BLUR := 1
const PASS_METALLIC := 2

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from `MetallicSettings` in `MetallicGui.cs` (lines 5-87). `reveal`
## is the "Metalic Reveal Slider": Materialize's preview-only split control,
## not part of the saved settings, kept here so the shell can move the seam.
static func defaults() -> Dictionary:
	return {
		# The picked metal colour, Materialize's `MS.MetalColor` (Color.black).
		"metal_color": Color(0.0, 0.0, 0.0, 1.0),
		# `MS.SampleUV`, the UV the colour was picked at. Unity samples the
		# blur map at this UV (`metalSample`) and never uses the sample, so
		# the key is stored for the project file, not read by the passes.
		"sample_uv": Vector2(0.0, 0.0),
		# The colour comparison faders and the mask edges.
		"hue_weight": 1.0,
		"sat_weight": 0.5,
		"lum_weight": 0.2,
		"mask_low": 0.0,
		"mask_high": 1.0,
		# The two blur radii, the overlay gain, and the final grade.
		"blur_size": 0.0,
		"overlay_blur_size": 30.0,
		"blur_overlay": 1.0,
		"final_contrast": 1.0,
		"final_bias": 0.0,
		# The source row: Unity's `useAdjustedDiffuse` / `useOriginalDiffuse`,
		# a radio pair with the pristine source on by default.
		"use_adjusted_diffuse": false,
		"use_original_diffuse": true,
		# Preview-only split seam (`Slider`), not part of the passes.
		"reveal": 0.5,
	}

## source: the diffuse map the shell runs the tool from, original: the pristine
## diffuse (`maps["diffuse_original"]`, Unity's `_DiffuseMapOriginal`), which
## " Use Original Diffuse" reads. blit: a Blit node already added to the scene
## tree. `params` overrides the settings this instance opened with; tests drive
## the passes with a dict. Returns the metallic mask in `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit, params: Dictionary, original: Image = null) -> Image:
	var s := defaults()
	for key in params:
		s[key] = params[key]

	# The radio row picks which diffuse the passes read. Unity's
	# `InitializeTextures` forces " Use Original Diffuse" when there is no
	# edited map (`MetallicGui.cs` lines 406-408), so a missing source falls
	# back to the map the shell passed in.
	var working: Image = Blit.to_float(source)
	if bool(s["use_original_diffuse"]) and original != null:
		working = Blit.to_float(original)

	var size := working.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Pass 1-2: the comparison blur. Unity skips the blur passes at Blur Size 0
	# and copies the source into `_BlurMap` straight
	# (`MetallicGui.cs` lines 493-495), so at 0 the blur map is the source.
	var blur_map: Image = working
	if float(s["blur_size"]) > 0.0:
		blur_map = await blit.blit(working, _blur_params(Vector2(1.0, 0.0), s["blur_size"]))
		blur_map = await blit.blit(blur_map, _blur_params(Vector2(0.0, 1.0), s["blur_size"]))

	# Pass 3-4: the overlay blur. "Overlay Blur Size" runs 10..100, so it is
	# always a real blur.
	var overlay_map := await blit.blit(working, _blur_params(Vector2(1.0, 0.0), s["overlay_blur_size"]))
	overlay_map = await blit.blit(overlay_map, _blur_params(Vector2(0.0, 1.0), s["overlay_blur_size"]))

	# Pass 5: fragMetallic. The selected diffuse rides in as the `source`
	# sampler, the two blurs as `blur_map` and `overlay_map`.
	return await blit.blit(working, _metallic_params(s, blur_map, overlay_map))

func _blur_params(axis: Vector2, size: float) -> Dictionary:
	return {
		"pass": PASS_BLUR,
		"direction": axis,
		"blur_size": float(size),
	}

func _metallic_params(s: Dictionary, blur_map: Image, overlay_map: Image) -> Dictionary:
	return {
		"pass": PASS_METALLIC,
		"blur_map": blur_map,
		"overlay_map": overlay_map,
		# The swatch rides in as a vec4 uniform, the way the Height tool's
		# colour samples do.
		"metal_color": s["metal_color"],
		"hue_weight": s["hue_weight"],
		"sat_weight": s["sat_weight"],
		"lum_weight": s["lum_weight"],
		"mask_low": s["mask_low"],
		"mask_high": s["mask_high"],
		"blur_overlay": s["blur_overlay"],
		"final_contrast": s["final_contrast"],
		"final_bias": s["final_bias"],
	}
