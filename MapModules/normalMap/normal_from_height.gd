class_name NormalFromHeight
extends RefCounted
## Normal From Height - Materialize's third tool, the pass driver.
##
## This is what Materialize runs in `ProcessHeight()` + `ProcessNormal()`
## (`Assets/Scripts/NormalFromHeightGui.cs`), driven pass by pass through the
## `Blit` framework:
##
##   1. LIGHT BLUR - four separable passes build a "light blur" reference from
##                   the source that will light the surface: the desaturated
##                   diffuse when "Shape from Diffuse" is on, otherwise the
##                   height map. The window is as wide as the Slope Blur slider
##                   (5..100 taps), so the reference keeps only the broad shapes.
##   2. NORMAL     - sobel slopes of the height map (`Pre Contrast` is the slope
##                   strength), plus the `Shape Recognition` shape built from
##                   `Light Rotation` and `Shape Bias`. Output is a normal map.
##   3. PYRAMID    - six progressive separable blurs of that normal map, each
##                   level a raised-cosine box blur with the spread sequence
##                   1, 1 + e, 1 + 3e, 1 + 7e, 1 + 15e, 1 + 15e + 16e.
##   4. COMBINE    - the seven levels re-blend by the Frequency Equalizer
##                   weights, then `Angularity` / `Angular Intensity` pull the
##                   normals towards the light, then `Final Contrast`.
##
## Why a blur pyramid on a normal map: each level is one scale of relief. The
## equalizer weights say how much of each scale survives, which is how "Smooth"
## keeps the broad shapes and "Crisp" keeps the sharp edges. `Angularity`
## flattens the normals towards the light direction, which is Materialize's
## trick for making surface relief read as baked-into-the-shading detail.

const SHADER_PATH := "res://MapModules/normalMap/normal_from_height.gdshader"

## Number of scales in the pyramid: level 0 is the sobel normal map, levels
## 1..6 are the progressive blurs.
const LEVELS := 7

## The shader passes, mirroring the Unity SubShader pass indices.
const PASS_BLUR := 1
const PASS_NORMAL := 3
const PASS_COMBINE := 4

## Materialize's Frequency Equalizer presets (`SetWeightEQDefault` /
## `SetWeightEQSmooth` / `SetWeightEQCrisp` / `SetWeightEQMids`). Index 0 is
## `Blur0Weight` (the sharp base), index 6 the coarsest level.
const PRESET_WEIGHTS := {
	"default": [0.3, 0.35, 0.5, 0.8, 1.0, 0.95, 0.8],
	"smooth": [0.1, 0.15, 0.25, 0.6, 0.9, 1.0, 1.0],
	"crisp": [1.0, 0.9, 0.6, 0.4, 0.25, 0.15, 0.1],
	"mids": [0.15, 0.5, 0.85, 1.0, 0.85, 0.5, 0.15],
}

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from NormalFromHeightSettings's constructor. `reveal` is the
## "Normal Reveal Slider": Materialize's preview-only split control, not part
## of the saved settings, kept here so the shell can move the seam.
static func defaults() -> Dictionary:
	return {
		"weights": [0.3, 0.35, 0.5, 0.8, 1.0, 0.95, 0.8],
		"pre_contrast": 20.0,
		"final_contrast": 5.0,
		"angularity": 0.0,
		"angular_intensity": 0.5,
		"use_diffuse": true,
		"shape_recognition": 0.0,
		"light_rotation": 0.0,
		"slope_blur": 50.0,
		"shape_bias": 0.5,
		"reveal": 0.5,
	}

func apply_weight_preset(preset: String) -> void:
	settings["weights"] = (PRESET_WEIGHTS[preset] as Array).duplicate()

## source: the height map (`Blit` format, any size). `blit` is the shared
## framework, already in the scene tree. The height map is Materialize's
## `_HeightMap`, so the module feeds that as the pass source.
## diffuse: the pristine source (`maps["diffuse_original"]`, Unity's
## `_DiffuseMapOriginal`), the "Shape from Diffuse" light input. May be null.
## Returns the normal map in `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit) -> Image:
	return await generate_from(source, blit, null)

func generate_from(source: Image, blit: Blit, diffuse: Image) -> Image:
	var working := Blit.to_float(source)
	var size := working.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Pass 1: the light blur. "Shape from Diffuse" uses the desaturated diffuse
	# as the light source, otherwise the height map itself. Unity runs the first
	# pass with `_Desaturate` on and turns it off for every pass after, so the
	# grey survives into the pyramid.
	var use_diffuse: bool = bool(settings["use_diffuse"]) and diffuse != null
	var light_map: Image = diffuse if use_diffuse else working
	var slope := clampf(float(settings["slope_blur"]), 5.0, 100.0)

	var light_blur := await blit.blit(light_map, _blur_params(Vector2(1.0, 0.0), 1.0, slope, 1 if use_diffuse else 0, true))
	light_blur = await blit.blit(light_blur, _blur_params(Vector2(0.0, 1.0), 1.0, slope, 0, true))

	# The second pair is wider: Unity's `SetFloat("_BlurSpread", 3.0)` pair,
	# which erases mid-frequency detail from the shape reference.
	light_blur = await blit.blit(light_blur, _blur_params(Vector2(1.0, 0.0), 3.0, slope, 0, true))
	light_blur = await blit.blit(light_blur, _blur_params(Vector2(0.0, 1.0), 3.0, slope, 0, true))

	# Pass 3: normal from height. Level 0 rides out as the pyramid's base.
	var levels: Array[Image] = [await blit.blit(working, _normal_params(light_map, light_blur))]

	# Pass 4: the pyramid. Each level is a separable blur of the previous one,
	# with the radius growing geometrically, the same spread sequence as the
	# height pyramid. Materialize blurs the *normal map* here, so `desaturate`
	# stays 0: the RGB normals must survive.
	var extra := (float(size.x + size.y) * 0.5) / 1024.0
	var spread := 1.0
	var step := extra

	for _level in range(1, LEVELS):
		var temp := await blit.blit(levels[-1], _blur_params(Vector2(1.0, 0.0), spread, float(4), 0, false))
		levels.append(await blit.blit(temp, _blur_params(Vector2(0.0, 1.0), spread, float(4), 0, false)))
		spread += step
		step *= 2.0

	# Pass 5: combine. Level 0 rides in as the `source` sampler, so blur1..blur6
	# are the pyramid levels 1..6, exactly Unity's `_BlurTex1`..`_BlurTex6`.
	return await blit.blit(levels[0], _combine_params(levels))

## One separable axis of the raised-cosine windowed box blur. `wide` picks the
## kernel: true is the 201-tap window the Slope Blur slider dials (Unity's
## `_BlurSamples = SlopeBlur`), false is the 9-tap pyramid blur (`_BlurSamples
## = 4`). Godot shader loops need a constant bound, so the two kernels are
## separate loops and `radius` scales the taps inside each: `radius / window`
## puts the window's zero-weight edge exactly at `radius` pixels.
func _blur_params(axis: Vector2, spread: float, radius: float, desaturate: int, wide: bool) -> Dictionary:
	return {
		"pass": PASS_BLUR,
		"direction": axis,
		"spread": spread,
		"radius": radius,
		"wide": 1 if wide else 0,
		"desaturate": desaturate,
		# Materialize runs every blur with contrast at 1.0; the contrast sliders
		# act in the normal and combine passes.
		"blur_contrast": 1.0,
	}

func _normal_params(light_map: Image, light_blur: Image) -> Dictionary:
	return {
		"pass": PASS_NORMAL,
		# Unity sets `_BlurContrast` to `Blur0Contrast` right before pass 3, so
		# `Pre Contrast` is the slope strength of the sobel.
		"blur_contrast": float(settings["pre_contrast"]),
		"light_map": light_map,
		"light_blur": light_blur,
		"light_rotation": float(settings["light_rotation"]),
		"shape_recognition": float(settings["shape_recognition"]),
		"shape_bias": float(settings["shape_bias"]),
	}

func _combine_params(levels: Array[Image]) -> Dictionary:
	var weights: Array = settings["weights"]
	var params := {
		"pass": PASS_COMBINE,
		"angularity": float(settings["angularity"]),
		"angular_intensity": float(settings["angular_intensity"]),
		"final_contrast": float(settings["final_contrast"]),
	}
	for index in range(1, LEVELS):
		params["blur%d" % index] = levels[index]
	for index in range(LEVELS):
		params["weight%d" % index] = float(weights[index])
	return params