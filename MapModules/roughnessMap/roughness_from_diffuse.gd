class_name RoughnessFromDiffuse
extends RefCounted
## Roughness Map - Materialize's Smoothness tool, the pass driver.
##
## This is what Materialize runs in `ProcessBlur()` + `ProcessSmoothness()`
## (`Assets/Scripts/SmoothnessGui.cs` lines 672-819), driven pass by pass
## through the `Blit` framework:
##
##   1. BLUR      - a separable raised-cosine blur at "Sample Blur Size", the
##                  softened colour the sample masks are measured on, and a
##                  second one at "High Pass Blur Size", the map subtracted from
##                  the sharp source to leave the high-frequency detail.
##   2. ROUGHNESS - fragSmoothness: the base level, the two colour sample
##                  masks, the level where the metallic map is metal, the high
##                  pass overlay, final contrast and bias, and "Isolate Mask".
##
## Unity's numbers are smoothness (1.0 = mirror). The maps are stored as
## roughness, so every level here is the inverted value: `roughness =
## 1 - smoothness`, which goes straight into `StandardMaterial3D.roughness_texture`.
##
## The source is picked by the window's two toggles: " Use Edited Diffuse"
## reads `_DiffuseMap`, " Use Original Diffuse" reads `_DiffuseMapOriginal`, the
## same pair the Metallic window has.

const SHADER_PATH := "res://MapModules/roughnessMap/roughness_from_diffuse.gdshader"

## The shader passes, mirroring the Unity SubShader pass indices
## (Blit_Shader blur pass 1, Blit_Smoothness smoothness pass 0).
const PASS_BLUR := 1
const PASS_ROUGHNESS := 2

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from `SmoothnessSettings` in `SmoothnessGui.cs` (lines 5-119), with
## every smoothness level inverted to roughness. `reveal` is the "Smoothness
## Reveal Slider": Materialize's preview-only split control, kept here so the
## shell can move the seam.
static func defaults() -> Dictionary:
	return {
		# The source row: Unity's `useAdjustedDiffuse` / `useOriginalDiffuse`,
		# a radio pair with the pristine source on by default.
		"use_adjusted_diffuse": false,
		"use_original_diffuse": true,
		# Preview-only split seam (`Slider`), not part of the passes.
		"reveal": 0.5,
		# Unity's `MetalSmoothness` 0.7: the level metal gets. Unity has no
		# "Use Metal" toggle, so the metallic map alone decides, and a missing
		# map is the flat default.
		"metal_roughness": 0.3,
		# Sample 1: Unity's defaults are the sample off with a black swatch,
		# `sample1Smoothness` 0.5.
		"use_sample1": false,
		"isolate_sample1": false,
		"sample_color1": Color(0.0, 0.0, 0.0, 1.0),
		# `SS.SampleUV1`, the UV the colour was picked at. Unity samples the
		# blur map at this UV (`sample1HSL`) and never uses the sample, so the
		# key is stored for the project file, not read by the passes.
		"sample_uv1": Vector2(0.0, 0.0),
		"hue_weight1": 1.0,
		"sat_weight1": 0.5,
		"lum_weight1": 0.2,
		"mask_low1": 0.0,
		"mask_high1": 1.0,
		"sample1_roughness": 0.5,
		# Sample 2, the same block: Unity's `sample2Smoothness` 0.3.
		"use_sample2": false,
		"isolate_sample2": false,
		"sample_color2": Color(0.0, 0.0, 0.0, 1.0),
		"sample_uv2": Vector2(0.0, 0.0),
		"hue_weight2": 1.0,
		"sat_weight2": 0.5,
		"lum_weight2": 0.2,
		"mask_low2": 0.0,
		"mask_high2": 1.0,
		"sample2_roughness": 0.7,
		# Unity's `BaseSmoothness` 0.1.
		"base_roughness": 0.9,
		# The two blur radii, the overlay gain, and the final grade. Unity's
		# "Sample Blur Size" runs 0..100 from 0, "High Pass Blur Size" 10..100
		# from 30.
		"blur_size": 0.0,
		"overlay_blur_size": 30.0,
		"blur_overlay": 3.0,
		"final_contrast": 1.0,
		"final_bias": 0.0,
	}

## source: the diffuse map the shell runs the tool from, original: the pristine
## diffuse (`maps["diffuse_original"]`, Unity's `_DiffuseMapOriginal`), which
## " Use Original Diffuse" reads. metallic: the metallic map the tool reads for
## the metal level, Unity's `_MetallicTex`. blit: a Blit node already added to
## the scene tree. `params` overrides the settings this instance opened with;
## tests drive the passes with a dict. Returns the roughness map in
## `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit, original: Image = null,
	metallic: Image = null, params: Dictionary = {}) -> Image:
	var s := defaults()
	for key in params:
		s[key] = params[key]

	# The radio row picks which diffuse the passes read. Unity forces
	# " Use Original Diffuse" when there is no edited map
	# (`SmoothnessGui.cs` lines 648-659), so a missing source falls back to the
	# map the shell passed in.
	var working: Image = Blit.to_float(source)
	if bool(s["use_original_diffuse"]) and original != null:
		working = Blit.to_float(original)

	var size := working.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Unity's `_DefaultMetallicMap` (`SmoothnessGui.cs` line 645): with no
	# metallic map, the box hands over a flat map, so no pixel is metal.
	var metal: Image = metallic if metallic != null \
		and metallic.get_size() == size and metallic.get_format() == Image.FORMAT_RGBAF \
		else Blit.flat(size, 0.0)

	# Pass 1-2: the sample blur. Unity copies the source straight at Blur Size 0
	# (`SmoothnessGui.cs` lines 783-797), so at 0 the blur map is the source.
	var blur_map: Image = working
	if float(s["blur_size"]) > 0.0:
		blur_map = await blit.blit(working, _blur_params(Vector2(1.0, 0.0), s["blur_size"]))
		blur_map = await blit.blit(blur_map, _blur_params(Vector2(0.0, 1.0), s["blur_size"]))

	# Pass 3-4: the overlay blur. "High Pass Blur Size" runs 10..100, so it is
	# always a real blur.
	var overlay_map := await blit.blit(working, _blur_params(Vector2(1.0, 0.0), s["overlay_blur_size"]))
	overlay_map = await blit.blit(overlay_map, _blur_params(Vector2(0.0, 1.0), s["overlay_blur_size"]))

	# Pass 5: fragSmoothness. The selected diffuse rides in as the `source`
	# sampler, the two blurs as `blur_map` and `overlay_map`, Unity's `_BlurTex`
	# and `_OverlayBlurTex`.
	return await blit.blit(working, _roughness_params(s, blur_map, overlay_map, metal))

func _blur_params(axis: Vector2, size: float) -> Dictionary:
	return {
		"pass": PASS_BLUR,
		"direction": axis,
		"blur_size": float(size),
	}

func _roughness_params(s: Dictionary, blur_map: Image, overlay_map: Image,
	metal: Image) -> Dictionary:
	var params := {}
	for key in defaults():
		# The source row, the preview seam, and the two blur radii are not
		# pass inputs: the row is picked before the chain runs, and the radii
		# only drive the blur passes.
		if key in ["use_adjusted_diffuse", "use_original_diffuse", "reveal",
				"blur_size", "overlay_blur_size", "sample_uv1", "sample_uv2"]:
			continue
		params[key] = s[key]
	params["pass"] = PASS_ROUGHNESS
	params["blur_map"] = blur_map
	params["overlay_map"] = overlay_map
	params["metal_map"] = metal
	return params
