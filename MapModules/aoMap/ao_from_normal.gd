class_name AOFromNormal
extends RefCounted
## AO Map - Materialize's Normal + Depth to AO tool, the pass driver.
##
## This is what Materialize runs in `ProcessNormalDepth()` + `ProcessAO()`
## (`Assets/Scripts/AOFromNormalGui.cs` lines 289-338 and 256-287), driven
## pass by pass through the `Blit` framework:
##
##   1. AO      - fragAO (Blit_Shader pass 7) 99 times, the loop Unity runs
##              (`for( int i = 1; i < 100; i++ )`, line 318): `progress = i /
##              100` turns the ray direction a full circle, 50 samples walk the
##              ray, and `blend_amount = 1 / i` lerps the pass into the
##              accumulator, so the accumulator ends up a running mean of ~100
##              directions. Unity copies pass 7's output into the blend texture
##              with a plain blit (line 324); the port feeds the accumulator
##              back as a sampler, which is the same accumulation in one pass.
##   2. COMBINE - fragCombineAO (pass 8): lerp the normal AO and the depth AO
##              at "Blend Normal AO and Depth AO", add "AO Bias", raise to the
##              power of "AO Power", saturate.
##
## The tool reads the Normal map, Unity's `_MainTex` on the AO blit line
## (`AOFromNormalGui.cs` line 323 blits `_NormalMap` straight), and the Height
## map, Unity's `_HeightTex`. Unity prefers `_HDHeightMap` over `_HeightMap`
## (lines 304-310); the port has one height map, so that map is the input.
## Missing maps fall back to Unity's flat defaults: `defaultNormal`
## (flat_normal.tga, a flat neutral normal) and `defaultHeight` (flat_grey.tga,
## 0.5 grey), the stand-ins `InitializeTextures` sets on lines 301 and 309.
##
## Unity seeds the ray jitter from `_Time.y` (fragAO line 362), a per-frame
## clock Godot has no equivalent of; the start offset is never read by the
## pass, so the port skips it. Unity applies AO Power, AO Bias and the blend to
## the preview material every frame while dragging (lines 159-161) and bakes
## them in pass 8 at Set time; the port bakes the grade in pass 2, so the
## shell's debounce re-runs the combine pass on every settle, documented.

const SHADER_PATH := "res://MapModules/aoMap/ao_from_normal.gdshader"

## The shader passes, mirroring the Unity SubShader pass indices
## (Blit_Shader AO pass 7, Combine AO pass 8).
const PASS_AO := 1
const PASS_COMBINE := 2

## Unity's accumulation sweep, `for( int i = 1; i < 100; i++ )` (line 318):
## pass 1..99, `progress = i / 100`, `blend_amount = 1 / i`.
const PASSES := 100

## Unity's 50-sample ray per pass, fragAO line 361 (`int AOSamples = 50`).
const AO_SAMPLES := 50

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from `AOSettings` in `AOFromNormalGui.cs` (lines 35-53). Unity
## opens the window with Blend 1 when a height map exists and Blend 0 when it
## does not (`InitializeSettings`, lines 108-114); the panel's `setup` applies
## that rule, and the default here is the height-present case.
static func defaults() -> Dictionary:
	return {
		# "AO pixel Spread", Unity's `Spread` 50: the ray length in pixels.
		"spread": 50.0,
		# "Pixel Depth", Unity's `Depth` 100: how steep a height step counts.
		"depth": 100.0,
		# "Blend Normal AO and Depth AO", Unity's `Blend`: 0 reads only the
		# normal term, 1 blends the depth AO in fully.
		"blend": 1.0,
		# "AO Power" and "AO Bias", Unity's `FinalContrast` 1 and `FinalBias` 0.
		"final_contrast": 1.0,
		"final_bias": 0.0,
	}

## source: the Normal map the shell runs the tool from, Unity's `_NormalMap`
## on the blit line. height: the Height map the depth term reads, Unity's
## `_HeightTex`. blit: a Blit node already added to the scene tree. `params`
## overrides the settings this instance opened with; tests drive the passes
## with a dict. Returns the AO map in `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit, height: Image = null,
	params: Dictionary = {}) -> Image:
	var s := defaults()
	for key in params:
		s[key] = params[key]

	var size := source.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Unity blits `_NormalMap` straight (line 323), so the source is the
	# Normal map as stored, signed (0.5 neutral), which the AO pass samples
	# raw in the port's Y-down frame (see the shader header).
	var normal: Image = source
	if normal == null:
		# Unity's defaultNormal, flat_normal.tga: (128, 128, 255) in the port's
		# signed convention. The shell gates Create on the normal map, so this
		# fallback is for direct calls.
		normal = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
		normal.fill(Color(0.5, 0.5, 1.0, 1.0))
	normal = Blit.to_float(normal)

	# Unity's defaultHeight, flat_grey.tga: 0.5 grey. A flat height makes the
	# depth term fully occluded (fragAO: no height step, so the geometric dot
	# reads 0), which is why Unity forces Blend 0 without a height map.
	var height_map: Image = height if height != null and height.get_size() == size \
		else Blit.flat(size, 0.5)

	# Unity's blend texture starts as an empty render texture, black RG, the
	# same seed the flat image gives. The accumulator carries AO.x (normal) in
	# red and AO.y (depth, inverted to the light side) in green.
	var passes: int = int(s.get("passes", PASSES))
	var accum := Blit.flat(size, 0.0)
	for i in range(1, passes):
		accum = await blit.blit(normal, _ao_params(s, height_map, accum, i, passes))

	return await blit.blit(normal, _combine_params(s, accum))

func _ao_params(s: Dictionary, height_map: Image, accum: Image, i: int, passes: int) -> Dictionary:
	return {
		"pass": PASS_AO,
		"height": height_map,
		"accumulator": accum,
		# Unity lines 320-321, the per-pass uniforms. The sweep count is a
		# setting so a test can shrink the chain; Unity's default is 100.
		"progress": float(i) / float(passes),
		"blend_amount": 1.0 / float(i),
		"samples": int(s.get("ao_samples", AO_SAMPLES)),
		"spread": float(s["spread"]),
		"depth": float(s["depth"]),
	}

func _combine_params(s: Dictionary, accum: Image) -> Dictionary:
	return {
		"pass": PASS_COMBINE,
		"accumulator": accum,
		# Unity ProcessAO lines 266-269, the final grade.
		"blend": float(s["blend"]),
		"final_contrast": float(s["final_contrast"]),
		"final_bias": float(s["final_bias"]),
	}
