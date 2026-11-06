class_name HeightFromDiffuse
extends RefCounted
## Height From Diffuse - the first Materialize tool ported to Godot.
##
## This is the algorithm Materialize runs in `ProcessDiffuse()`
## (Assets/Scripts/HeightFromDiffuseGui.cs), driven pass by pass through the
## `Blit` framework:
##
##   1. SAMPLE   - the source image becomes a grey base height. Optional colour
##                 sample masks can push specific pixels to chosen heights.
##   2. PYRAMID  - six progressive separable blurs build a scale ladder, each
##                 level a raised-cosine box blur with a doubled radius.
##   3. AVERAGE  - a very wide blur of level 6 becomes the low-frequency
##                 reference (the "average colour" materialize subtracts).
##   4. COMBINE  - every level contributes its deviation from that reference,
##                 gamma-lifted, weighted, normalised, then final contrast,
##                 bias, and split gain.
##
## The point of subtracting the average: height should be local relief, not the
## brightness gradient of the photograph. A photo lit from one side has a big
## slow luminance ramp, and that ramp must not become a slope in the height map.
## The pyramid plus average subtraction keeps only detail at each scale.

const SHADER_PATH := "res://MapModules/heightMap/height_from_diffuse.gdshader"

## Number of scales in the pyramid: level 0 is the sharp base, levels 1..6 are
## the progressive blurs.
const LEVELS := 7

## The shader passes, mirroring the Unity SubShader pass indices.
const PASS_SAMPLE := 0
const PASS_BLUR := 1
const PASS_COMBINE := 2
const PASS_AVG := 3

## Materialize's weight presets (SetWeightEQDefault / Detail / Displace).
const PRESET_WEIGHTS := {
	"default": [0.15, 0.19, 0.3, 0.5, 0.7, 0.9, 1.0],
	"detail": [0.7, 0.4, 0.3, 0.5, 0.8, 0.9, 0.7],
	"displace": [0.02, 0.03, 0.1, 0.35, 0.7, 0.9, 1.0],
}

## Materialize's contrast presets (SetContrastEQDefault / CrackedMud / Funky).
const PRESET_CONTRASTS := {
	"default": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
	"cracked_mud": [1.0, 1.0, 1.0, 1.0, -0.2, -2.0, -4.0],
	"funky": [-3.0, -1.2, 0.3, 1.3, 2.0, 2.5, 2.0],
}

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from HeightFromDiffuseSettings's constructor.
static func defaults() -> Dictionary:
	return {
		"weights": [0.15, 0.19, 0.3, 0.5, 0.7, 0.9, 1.0],
		"contrasts": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
		"final_contrast": 1.5,
		"final_bias": 0.0,
		"final_gain": 0.0,
		"sample1": {
			"use": false, "isolate": false, "color": Color(0.0, 0.0, 0.0, 1.0),
			"hue": 1.0, "sat": 0.5, "lum": 0.2,
			"mask_low": 0.0, "mask_high": 1.0, "height": 0.5,
		},
		"sample2": {
			"use": false, "isolate": false, "color": Color(0.0, 0.0, 0.0, 1.0),
			"hue": 1.0, "sat": 0.5, "lum": 0.2,
			"mask_low": 0.0, "mask_high": 1.0, "height": 0.3,
		},
		"sample_blend": 0.5,
		# Materialize's source row (Diffuse / Original Diffuse / Normal) and the
		# preview Height Reveal Slider. Only the loaded diffuse is implemented
		# for now; the reveal slider is a preview control, not an output setting.
		"use_adjusted_diffuse": true,
		"use_original_diffuse": false,
		"use_normal": false,
		"reveal": 1.0,
	}

## Materialize maps the gain slider to an exponent before using it: positive
## values shift up by 1, negative values become the reciprocal of (gain - 1).
## A slider of 0 means exponent 1, i.e. no gain change.
static func gain_mapping(gain: float) -> float:
	if gain < 0.0:
		return abs(1.0 / (gain - 1.0))
	return gain + 1.0

func apply_weight_preset(preset: String) -> void:
	settings["weights"] = (PRESET_WEIGHTS[preset] as Array).duplicate()

func apply_contrast_preset(preset: String) -> void:
	settings["contrasts"] = (PRESET_CONTRASTS[preset] as Array).duplicate()

## source: the diffuse image (any format, any size).
## blit: a Blit node already added to the scene tree.
## Returns the height map in `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit) -> Image:
	var working := Blit.to_float(source)
	var size := working.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Pass 1: grey base, with colour sample masks applied.
	var base := await blit.blit(working, _sample_params())

	# Pass 2: the pyramid. Each level is a separable blur of the previous one,
	# with the radius growing geometrically. Materialize's spread sequence is
	# 1, 1 + e, 1 + 3e, 1 + 7e, 1 + 15e, 1 + 31e where e is (width + height) / 2
	# divided by 1024, so the ladder scales with image size.
	var levels: Array[Image] = [base]
	var extra := (float(size.x + size.y) * 0.5) / 1024.0
	var spread := 1.0
	var step := extra

	for _level in range(1, LEVELS):
		var temp := await blit.blit(levels[-1], _blur_params(Vector2(1.0, 0.0), spread))
		levels.append(await blit.blit(temp, _blur_params(Vector2(0.0, 1.0), spread)))
		spread += step
		step *= 2.0

	# Pass 3: the low-frequency reference. Materialize blurs level 6 with 65
	# taps at 31 times the base radius, twice.
	var avg_spread := 64.0 * extra
	var avg := await blit.blit(levels[LEVELS - 1], _avg_params(Vector2(1.0, 0.0), avg_spread))
	avg = await blit.blit(avg, _avg_params(Vector2(0.0, 1.0), avg_spread))

	# Pass 4: combine. Level 0 rides in as the `source` sampler.
	return await blit.blit(levels[0], _combine_params(levels, avg))

func _sample_params() -> Dictionary:
	var sample1: Dictionary = settings["sample1"]
	var sample2: Dictionary = settings["sample2"]
	return {
		"pass": PASS_SAMPLE,
		"use_sample1": 1 if sample1["use"] else 0,
		"isolate_sample1": 1 if sample1["isolate"] else 0,
		"sample_color1": sample1["color"],
		"hue_weight1": sample1["hue"],
		"sat_weight1": sample1["sat"],
		"lum_weight1": sample1["lum"],
		"mask_low1": sample1["mask_low"],
		"mask_high1": sample1["mask_high"],
		"sample1_height": sample1["height"],
		"use_sample2": 1 if sample2["use"] else 0,
		"isolate_sample2": 1 if sample2["isolate"] else 0,
		"sample_color2": sample2["color"],
		"hue_weight2": sample2["hue"],
		"sat_weight2": sample2["sat"],
		"lum_weight2": sample2["lum"],
		"mask_low2": sample2["mask_low"],
		"mask_high2": sample2["mask_high"],
		"sample2_height": sample2["height"],
		# Materialize zeroes the blend when no sample is in use.
		"sample_blend": settings["sample_blend"] if (sample1["use"] or sample2["use"]) else 0.0,
	}

func _blur_params(axis: Vector2, spread: float) -> Dictionary:
	return {
		"pass": PASS_BLUR,
		"direction": axis,
		"spread": spread,
		# Materialize runs the pyramid with contrast at 1.0; the per-level
		# contrast sliders act in the combine pass instead.
		"blur_contrast": 1.0,
	}

func _avg_params(axis: Vector2, spread: float) -> Dictionary:
	return {
		"pass": PASS_AVG,
		"direction": axis,
		"spread": spread,
		"blur_contrast": 1.0,
	}

func _combine_params(levels: Array[Image], avg: Image) -> Dictionary:
	var weights: Array = settings["weights"]
	var contrasts: Array = settings["contrasts"]
	var params := {
		"pass": PASS_COMBINE,
		"avg_map": avg,
		"final_contrast": settings["final_contrast"],
		"final_bias": settings["final_bias"],
		"final_gain": gain_mapping(float(settings["final_gain"])),
	}
	# blur1..blur6 are the pyramid levels 1..6; level 0 is the pass source.
	for index in range(1, LEVELS):
		params["blur%d" % index] = levels[index]
	for index in range(LEVELS):
		params["weight%d" % index] = float(weights[index])
		params["contrast%d" % index] = float(contrasts[index])
	return params
