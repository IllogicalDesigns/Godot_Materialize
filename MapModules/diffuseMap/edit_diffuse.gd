class_name DiffuseGenerator
extends RefCounted
## Diffuse Map - Materialize's "Edit Diffuse" tool ported to Godot.
##
## This is the algorithm Materialize runs in the Edit Diffuse window
## (`EditDiffuseGui.cs`), driven pass by pass through the `Blit` framework:
##
##   1. OVERLAY  - a separable raised-cosine blur of the source, at the
##                 Overlay Blur Size. Its difference from the sharp source is
##                 the detail the tool re-amplifies.
##   2. AVERAGE  - a much wider separable blur of the source, at the Average
##                 Color Blur Size. This is the low-frequency colour the tool
##                 removes, the same role the average map plays in Height.
##   3. EDIT     - fragEditDiffuse: spot removal, lighting removal, overlay,
##                 colour restore, final contrast / bias, saturation.
##
## Unity stacked many narrow blur passes per map (Blit_Shader pass 1, run
## `2 * ceil(2 * blurSize)` times with alternating directions). Each Godot pass
## costs a frame, so the port runs one horizontal and one vertical pass per map
## with the full radius: the same raised-cosine window, the same spread, one
## frame.
##
## The tool always reads the pristine source image, Materialize's
## `_DiffuseMapOriginal`, so the passes never see their own output.

const SHADER_PATH := "res://MapModules/diffuseMap/edit_diffuse.gdshader"

## The shader passes, mirroring the Unity SubShader pass indices
## (Blit_Shader.shader: blur pass 1, fragEditDiffuse pass 11).
const PASS_BLUR := 1
const PASS_EDIT := 2

var settings: Dictionary = {}

func _init() -> void:
	settings = defaults()

## Defaults from `EditDiffuseGui.cs`'s `EDDS` fields (lines 46-64): the
## Materialize slider ranges and their initial values.
static func defaults() -> Dictionary:
	return {
		# Preview-only split seam (`EDDS.Slider`), not part of the passes.
		"reveal": 0.5,
		# Materialize reads "Average Color Blur Size" first (lines 495-503).
		"average_blur": 50.0,
		"overlay_blur": 20.0,
		"overlay_blur_contrast": 0.0,
		"light_mask_power": 0.5,
		"remove_light": 0.0,
		"shadow_mask_power": 0.5,
		"remove_shadow": 0.0,
		"hot_spot_removal": 0.0,
		"dark_spot_removal": 0.0,
		"final_contrast": 1.0,
		"final_bias": 0.0,
		"keep_original_color": 0.5,
		"saturation": 1.0,
	}

## source: the pristine diffuse image (any format, any size).
## blit: a Blit node already added to the scene tree.
## Returns the edited diffuse map in `FORMAT_RGBAF`.
func generate(source: Image, blit: Blit) -> Image:
	var working := Blit.to_float(source)
	var size := working.get_size()
	blit.setup(load(SHADER_PATH), size)

	# Pass 1-2: the overlay blur, one separable axis per pass.
	var overlay_blur := await blit.blit(working,
			_blur_params(Vector2(1.0, 0.0), settings["overlay_blur"]))
	overlay_blur = await blit.blit(overlay_blur,
			_blur_params(Vector2(0.0, 1.0), settings["overlay_blur"]))

	# Pass 3-4: the average colour map.
	var avg := await blit.blit(working,
			_blur_params(Vector2(1.0, 0.0), settings["average_blur"]))
	avg = await blit.blit(avg,
			_blur_params(Vector2(0.0, 1.0), settings["average_blur"]))

	# Pass 5: fragEditDiffuse. The sharp source rides in as the `source`
	# sampler, the two blurs as `blur_map` and `avg_map`.
	return await blit.blit(working, _edit_params(overlay_blur, avg))

func _blur_params(axis: Vector2, size: float) -> Dictionary:
	return {
		"pass": PASS_BLUR,
		"direction": axis,
		"blur_size": float(size),
	}

func _edit_params(overlay_blur: Image, avg: Image) -> Dictionary:
	return {
		"pass": PASS_EDIT,
		"blur_map": overlay_blur,
		"avg_map": avg,
		# The shader remaps the mask powers the way fragEditDiffuse does, so
		# the settings keys go straight through.
		"hot_spot": settings["hot_spot_removal"],
		"dark_spot": settings["dark_spot_removal"],
		"light_mask_pow": settings["light_mask_power"],
		"dark_mask_pow": settings["shadow_mask_power"],
		"light_pow": settings["remove_light"],
		"dark_pow": settings["remove_shadow"],
		"blur_contrast": settings["overlay_blur_contrast"],
		"color_lerp": settings["keep_original_color"],
		"final_contrast": settings["final_contrast"],
		"final_bias": settings["final_bias"],
		"saturation": settings["saturation"],
	}
