extends Node2D
## CPU reference for the Diffuse map tool, mirroring `fragBlur` and
## `fragEditDiffuse` in Blit_Shader.shader and `Photoshop.cginc` channel by
## channel, in GDScript. It runs the same chain as the GPU shader on the stone
## test pattern at 64 x 64 (the CPU blur is slow), prints both results'
## statistics, and checks that the GPU pass chain matches the CPU math.
##
## Run the GPU test on the same pattern and the same settings:
##   DISPLAY=:1 godot --path . res://tests/diffuse_cpu.tscn
##
## The CPU port is the reference, exactly like `tests/height_cpu.gd` for the
## Height tool: it is the check that the shader wiring, the sampler names, and
## the settings keys all reach the same numbers Unity's window produced.

const GREY := Vector3(0.3, 0.5, 0.2)
const SIZE := Vector2i(64, 64)

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var tool := DiffuseGenerator.new()
	var source := TestPattern.stone(SIZE)

	# The neutral defaults.
	var gpu_neutral := await tool.generate(source, blit)
	var cpu_neutral := _reference(source, tool.settings)
	_compare("neutral", source, cpu_neutral, gpu_neutral)

	# The strong settings, same as the GPU test.
	tool.settings["final_contrast"] = 2.0
	tool.settings["final_bias"] = 0.1
	tool.settings["saturation"] = 0.0
	tool.settings["hot_spot_removal"] = 1.0
	tool.settings["dark_spot_removal"] = 1.0
	tool.settings["overlay_blur_contrast"] = 1.0
	var gpu_strong := await tool.generate(source, blit)
	var cpu_strong := _reference(source, tool.settings)
	_compare("strong", source, cpu_strong, gpu_strong)

	get_tree().quit()

func _reference(source: Image, settings: Dictionary) -> Image:
	var overlay_blur := _blur(source, float(settings["overlay_blur"]))
	var avg := _blur(source, float(settings["average_blur"]))
	var size := source.get_size()
	var result := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	for y in size.y:
		for x in size.x:
			result.set_pixel(x, y, _edit(source.get_pixel(x, y),
					overlay_blur.get_pixel(x, y), avg.get_pixel(x, y), settings))
	return result

## fragBlur run on both axes, with the raised-cosine window the shader uses.
func _blur(image: Image, radius: float) -> Image:
	var size := image.get_size()
	var horizontal := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	var vertical := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	var r := int(radius)
	for y in size.y:
		for x in size.x:
			horizontal.set_pixel(x, y, _blur_axis(image, x, y, Vector2i(1, 0), radius, r))
	for y in size.y:
		for x in size.x:
			vertical.set_pixel(x, y, _blur_axis(horizontal, x, y, Vector2i(0, 1), radius, r))
	return vertical

func _blur_axis(image: Image, x: int, y: int, axis: Vector2i, radius: float, r: int) -> Color:
	var total := Vector3.ZERO
	var weight_sum := 0.0
	var size := image.get_size()
	for i in range(-r, r + 1):
		var t := float(i) / maxf(radius, 1.0)
		var weight := cos(t * PI) * 0.5 + 0.5
		var sx := (x + i * axis.x) % size.x
		if sx < 0:
			sx += size.x
		var sy := (y + i * axis.y) % size.y
		if sy < 0:
			sy += size.y
		var pixel: Color = image.get_pixel(sx, sy)
		total += Vector3(pixel.r, pixel.g, pixel.b) * weight
		weight_sum += weight
	var blurred := total / weight_sum
	return Color(blurred.x, blurred.y, blurred.z, 1.0)

## fragEditDiffuse for one pixel.
func _edit(main: Color, blur: Color, avg: Color, settings: Dictionary) -> Color:
	var main_v := Vector3(main.r, main.g, main.b)
	var blur_v := Vector3(blur.r, blur.g, blur.b)
	var avg_v := Vector3(avg.r, avg.g, avg.b)

	var overlay := main_v - blur_v
	var initial_hsl := _rgb_to_hsl(main_v)

	# spot removal
	var avg_lum := main_v.dot(GREY)
	var hot := float(settings["hot_spot_removal"])
	var dark := float(settings["dark_spot_removal"])
	var light_mask := _smoothstep(1.0 - hot, (1.0 - hot) + pow(hot, 0.5) + 0.01, avg_lum)
	var dark_mask := _smoothstep(dark - pow(dark, 0.5) - 0.01, dark, avg_lum)
	main_v = main_v.lerp(avg_v, 1.0 - (1.0 - light_mask) * dark_mask)

	# Lighting removal
	var lmp := float(settings["light_mask_power"])
	var dmp := float(settings["shadow_mask_power"])
	var light_pow_p: float = clampf((lmp - 0.5) * 2.0, 0.0, 1.0) + 1.0
	light_pow_p -= 1.0 - (1.0 / (clampf((lmp - 0.5) * -2.0, 0.0, 1.0) + 1.0))
	var dark_pow_p: float = clampf((dmp - 0.5) * 2.0, 0.0, 1.0) + 1.0
	dark_pow_p -= 1.0 - (1.0 / (clampf((dmp - 0.5) * -2.0, 0.0, 1.0) + 1.0))

	main_v -= avg_v
	var grey := main_v.dot(GREY)
	var high_mask := Vector3.ONE * pow(clampf(grey * 2.0, 0.001, 0.99), light_pow_p)
	var low_mask := Vector3.ONE * pow(clampf(-grey * 2.0, 0.001, 0.99), dark_pow_p)
	main_v += Vector3.ONE * 0.5

	var light_pow := float(settings["remove_light"])
	var dark_pow := float(settings["remove_shadow"])
	# Unity's `lerp(mainTex, ..., mainTexHighMask)` is a per-channel lerp,
	# which Vector3.lerp (scalar weight) cannot express. Do it channel by
	# channel, exactly as the shader's `mix` does.
	main_v = _lerp_mask(main_v, main_v * (1.0 - light_pow), high_mask)
	main_v = _lerp_mask(main_v, Vector3.ONE - (Vector3.ONE - main_v) * (1.0 - dark_pow), low_mask)

	var desaturate := high_mask.x * light_pow
	desaturate += low_mask.x * dark_pow * 2.0
	desaturate += 1.0 - (1.0 - light_mask) * dark_mask
	desaturate = 1.0 - clampf(desaturate, 0.0, 1.0)

	# apply overlay
	var overlay_mask := 1.0 - (1.0 - high_mask.x * light_pow) * (1.0 - low_mask.x * dark_pow)
	overlay_mask = clampf(overlay_mask * 2.0 + 0.1, 0.0, 1.0)
	var overlay_strength := overlay * float(settings["overlay_blur_contrast"]) * 10.0 + Vector3.ONE
	main_v = main_v * (overlay_strength * overlay_mask + Vector3.ONE * (1.0 - overlay_mask))
	main_v = Vector3(clampf(main_v.x, 0.0, 1.0), clampf(main_v.y, 0.0, 1.0), clampf(main_v.z, 0.0, 1.0))

	# maintain color
	var hsl := _rgb_to_hsl(main_v)
	hsl.x = initial_hsl.x
	hsl.y = initial_hsl.y
	var restored := _hsl_to_rgb(hsl)
	var color_lerp := float(settings["keep_original_color"]) * desaturate
	main_v = main_v.lerp(restored, color_lerp)

	# brightness and contrast
	main_v = (main_v - Vector3.ONE * 0.5) * float(settings["final_contrast"]) + Vector3.ONE * 0.5 + Vector3.ONE * float(settings["final_bias"])
	main_v = Vector3(clampf(main_v.x, 0.0, 1.0), clampf(main_v.y, 0.0, 1.0), clampf(main_v.z, 0.0, 1.0))

	# Saturation
	var sat := float(settings["saturation"])
	var luminance := main_v.dot(GREY)
	main_v = main_v.lerp(Vector3.ONE * luminance, 1.0 - sat)

	return Color(main_v.x, main_v.y, main_v.z, 1.0)

func _lerp_mask(a: Vector3, b: Vector3, t: Vector3) -> Vector3:
	# Component-wise lerp, the shader's `mix(a, b, mask)` with a vec3 mask.
	return a + (b - a) * t

func _rgb_to_hsl(value: Vector3) -> Vector3:
	var fmin := minf(value.x, minf(value.y, value.z))
	var fmax := maxf(value.x, maxf(value.y, value.z))
	var delta := fmax - fmin
	var hsl := Vector3(0.0, 0.0, (fmax + fmin) * 0.5)
	if delta == 0.0:
		return hsl
	if hsl.z < 0.5:
		hsl.y = delta / (fmax + fmin)
	else:
		hsl.y = delta / (2.0 - fmax - fmin)
	var delta_r := (((fmax - value.x) / 6.0) + (delta * 0.5)) / delta
	var delta_g := (((fmax - value.y) / 6.0) + (delta * 0.5)) / delta
	var delta_b := (((fmax - value.z) / 6.0) + (delta * 0.5)) / delta
	if value.x == fmax:
		hsl.x = delta_b - delta_g
	elif value.y == fmax:
		hsl.x = (1.0 / 3.0) + delta_r - delta_b
	else:
		hsl.x = (2.0 / 3.0) + delta_g - delta_r
	if hsl.x < 0.0:
		hsl.x += 1.0
	elif hsl.x > 1.0:
		hsl.x -= 1.0
	return hsl

func _hsl_to_rgb(hsl: Vector3) -> Vector3:
	var result := Vector3(hsl.z, hsl.z, hsl.z)
	if hsl.y > 0.0:
		var right: float = hsl.z * (1.0 + hsl.y) if hsl.z < 0.5 else hsl.z + hsl.y - hsl.z * hsl.y
		var left: float = 2.0 * hsl.z - right
		result.x = _hue_to_rgb(left, right, hsl.x * 6.0 + 2.0)
		result.y = _hue_to_rgb(left, right, hsl.x * 6.0)
		result.z = _hue_to_rgb(left, right, hsl.x * 6.0 - 2.0)
	return result

func _hue_to_rgb(left: float, right: float, value: float) -> float:
	value = value - 6.0 if value > 6.0 else value
	value = value + 6.0 if value < 0.0 else value
	if value > 4.0:
		value = 1.0 - value * 0.25
	elif value < 1.0:
		value = value
	else:
		value = 1.0
	return lerpf(left, right, value)

func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	if edge1 <= edge0:
		return 1.0 if value >= edge0 else 0.0
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _compare(label: String, source: Image, cpu: Image, gpu: Image) -> void:
	var size := source.get_size()
	var worst := 0.0
	var cpu_mean := 0.0
	var gpu_mean := 0.0
	for y in size.y:
		for x in size.x:
			var c: Color = cpu.get_pixel(x, y)
			var g: Color = gpu.get_pixel(x, y)
			worst = maxf(worst, maxf(absf(c.r - g.r), maxf(absf(c.g - g.g), absf(c.b - g.b))))
			cpu_mean += (c.r + c.g + c.b) / 3.0
			gpu_mean += (g.r + g.g + g.b) / 3.0
	cpu_mean /= float(size.x * size.y)
	gpu_mean /= float(size.x * size.y)
	var verdict := "PASS" if worst < 0.01 else "FAIL"
	print("%s CPU mean %.3f GPU mean %.3f max pixel delta %.4f -> %s" % [label, cpu_mean, gpu_mean, worst, verdict])
