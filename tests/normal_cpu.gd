extends Node
## CPU reference for the Normal From Height pass chain.
##
## Mirrors Materialize's Blit_Shader pass chain and Blit_Normal_From_Height
## passes in pure GDScript, on the same inputs the shell uses: the stone test
## pattern is the light source ("Shape from Diffuse"), and the sobel runs on the
## height map, which this mirror builds with `tests/height_cpu.gd` because
## `NormalMapModule.source_map_type()` is "height". It prints the statistics the
## live test asserts. Godot's GPU pass chain
## (`MapModules/normalMap/normal_from_height.gdshader`) is the production code;
## this file is the readable mirror that proves what a real normal map looks
## like so the numbers can be checked:
##  - a flat source gives a neutral map (0.5, 0.5, 1.0): red and green neutral,
##    blue up,
##  - a detail source gives relief: blue mean well above 0.5, red near neutral,
##    spread well above zero,
##  - the Smooth preset gives flatter relief than the Crisp preset.
##
## Run headless: `godot --path . --headless res://tests/normal_cpu.tscn`
## The size is the shell's smallest resolution, so the live test
## (`tests/normal_live.tscn`) can assert against these numbers. It writes
## `user://normal_cpu/result.png`, `smooth.png`, `crisp.png` for looking at.

# Import the driver for its constants and defaults so this reference can never
# drift from the pass ids and parameter names the driver uses.
const NormalFromHeight := preload("res://MapModules/normalMap/normal_from_height.gd")
# The height map the shell feeds the sobel comes from Height From Diffuse
# (`NormalMapModule.source_map_type()` is "height"), so this mirror builds the
# same height map with `tests/height_cpu.gd` and uses that as the source. Using
# the raw stone here is what made the mirror read twice the tilt of the GPU.
const HeightCpu := preload("res://tests/height_cpu.gd")

const LEVELS := 7
const SIZE := 512

func _ready() -> void:
	_run()

func _run() -> void:
	var stone := TestPattern.stone(Vector2i(SIZE, SIZE))
	var failures: Array[String] = []
	var height_map: Image = (HeightCpu.new() as Node).call("_pipeline", stone) as Image

	# The slider settings the live test drives through the panel: Slope Blur
	# 75, Final Contrast 3, Shape Bias 0.5, everything else at the Unity
	# window's defaults.
	var settings := NormalFromHeight.defaults()
	settings["slope_blur"] = 75.0
	settings["final_contrast"] = 3.0
	settings["shape_bias"] = 0.5

	# Flat grey source: the pass chain must give exactly the neutral normal map,
	# which is 0.5, 0.5, 1.0 in the signed convention. This is the base check
	# that the pass chain produces normals, not shading. The flat stands in for
	# the height map of a flat source, which the height chain leaves flat.
	var flat_result := _pipeline(_flat(SIZE, 0.4), settings)
	var flat_stats := _stats(flat_result)
	var ok_flat: bool = abs(flat_stats["mean_r"] - 0.5) < 0.01 \
			and abs(flat_stats["mean_g"] - 0.5) < 0.01 \
			and flat_stats["mean_b"] > 0.95 and flat_stats["spread"] < 0.01 \
			and flat_stats["tilt"] < 0.01
	print("flat grey source -> ", flat_stats, "  expect neutral normal (mean 0.5/0.5/1.0, spread and tilt 0),"
			+ " got neutral: ", ok_flat)
	if not ok_flat:
		failures.append("flat source is not neutral")

	var stone_result := _pipeline(height_map, settings)
	print("stone diffuse -> ", _stats(stone))
	print("stone height  -> ", _stats(height_map))
	print("stone result  -> ", _stats(stone_result))
	var ok_relief: bool = stone_result.get_pixel(2, 2).b > 0.6 \
			and abs(_stats(stone_result)["mean_r"] - 0.5) < 0.1 \
			and _stats(stone_result)["spread"] > 0.02
	print("expect a normal map (blue mean above 0.5, red near 0.5, spread above 0.02),"
			+ " got: ", ok_relief)
	if not ok_relief:
		failures.append("stone result is not a normal map")

	# The Frequency Equalizer presets are the equalizer weights, so the same
	# source must read smoother with Smooth and crisper with Crisp.
	var smooth_settings := settings.duplicate()
	smooth_settings["weights"] = NormalFromHeight.PRESET_WEIGHTS["smooth"]
	var smooth_result := _pipeline(height_map, smooth_settings)
	var crisp_settings := settings.duplicate()
	crisp_settings["weights"] = NormalFromHeight.PRESET_WEIGHTS["crisp"]
	var crisp_result := _pipeline(height_map, crisp_settings)
	print("stone smooth -> ", _stats(smooth_result))
	print("stone crisp  -> ", _stats(crisp_result))
	var ok_presets: bool = _stats(smooth_result)["spread"] < _stats(crisp_result)["spread"] \
			and _stats(smooth_result)["tilt"] < _stats(crisp_result)["tilt"]
	print("expect Smooth spread and tilt below Crisp's (Smooth keeps the broad scales,"
			+ " Crisp keeps the sharp ones), got: ", ok_presets)
	if not ok_presets:
		failures.append("presets do not reorder the scales")

	var dir := "user://normal_cpu/"
	DirAccess.make_dir_recursive_absolute(dir)
	for entry: Array in [["result", stone_result], ["smooth", smooth_result], ["crisp", crisp_result]]:
		var out: Image = entry[1].duplicate()
		out.convert(Image.FORMAT_RGBA8)
		out.save_png(dir + entry[0] + ".png")
	print("Wrote ", dir, "result.png, smooth.png, crisp.png")

	if failures.is_empty():
		print("PASS: the normal pass chain is real, flat surfaces stay neutral, and the"
				+ " presets reorder the scales")
	else:
		for failure in failures:
			print("FAIL: %s" % failure)
		print("normal cpu: FAIL")
	get_tree().quit()

func _flat(size: int, value: float) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBAF)
	image.fill(Color(value, value, value, 1.0))
	return image

func _pipeline(source: Image, settings: Dictionary) -> Image:
	var size: Vector2i = source.get_size()

	# Pass 1: the light blur. "Shape from Diffuse" uses the desaturated source;
	# otherwise the height map itself, with no desaturate. The port has no
	# separate diffuse here, so the source doubles as both, the way the driver
	# falls back when no diffuse map exists.
	var slope := clampf(float(settings["slope_blur"]), 5.0, 100.0)
	var light_blur := _blur(source, 0, 1.0, slope, 100, settings["use_diffuse"] == true)
	light_blur = _blur(light_blur, 1, 1.0, slope, 100, false)
	light_blur = _blur(light_blur, 0, 3.0, slope, 100, false)
	light_blur = _blur(light_blur, 1, 3.0, slope, 100, false)

	# Pass 3: sobel normal from the height map.
	var contrast := clampf(float(settings["pre_contrast"]), 0.1, 50.0)
	var level0 := _blit(source, NormalFromHeight.PASS_NORMAL,
		_normal_params(settings, contrast, source, light_blur))

	# Pass 4: six progressive pyramid blurs. `extra` grows the spread by the
	# source size, which is what makes each level smoother than the last. Same
	# convention as `MapModules/heightMap/height_from_diffuse.gd`, so the
	# pyramid matches the driver pass for pass.
	var levels: Array = [level0]
	var extra := (float(size.x + size.y) * 0.5) / 1024.0
	var spread := 1.0
	var step := extra

	for _level in range(1, LEVELS):
		var temp := _blur(levels[-1], 0, spread, 4.0, 4, false)
		levels.append(_blur(temp, 1, spread, 4.0, 4, false))
		spread += step
		step *= 2.0

	# Pass 5: combine by the equalizer weights.
	return _combine(levels, settings)

## One separable axis of the raised-cosine windowed box blur: Materialize's
## fragBlur, `radius / window` scaling the taps so the window's zero-weight edge
## lands at `radius` pixels. `samples` is the constant kernel bound, matching
## the shader's two loops.
##
## Sampling convention: taps are rounded to the nearest texel and clamped at the
## edge, where the GPU shader samples linearly with `repeat_enable`. The
## difference is second-order (a small blur-kernel fade at the seams), so the
## live test's tolerances cover it; the height CPU mirror
## (`tests/height_cpu.gd`) uses the linear + wrap convention, so the height map
## fed into this mirror is the GPU convention.
func _blur(image: Image, axis: int, spread: float, radius: float, samples: int, desaturate: bool) -> Image:
	var size: Vector2i = image.get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	var total := 0.0
	for i in range(-samples, samples + 1):
		total += cos(float(i) / float(samples * 2) * TAU) * 0.5 + 0.5

	for y in range(size.y):
		for x in range(size.x):
			var sum := Vector3(0.0, 0.0, 0.0)
			for i in range(-samples, samples + 1):
				var weight := cos(float(i) / float(samples * 2) * TAU) * 0.5 + 0.5
				var color := _sample(image, x, y, axis, float(i) * spread * radius / float(samples), size)
				var tap := Vector3(color.r, color.g, color.b)
				if desaturate:
					var grey := tap.x * 0.3 + tap.y * 0.5 + tap.z * 0.2
					tap = Vector3(grey, grey, grey)
				sum += tap * weight
			var value: Vector3 = sum / total
			# Materialize runs every blur with contrast 1.0, so the clamp is the
			# only change, and grey normals survive the pyramid untouched.
			out.set_pixel(x, y, Color(clampf(value.x, 0.0, 1.0), clampf(value.y, 0.0, 1.0),
				clampf(value.z, 0.0, 1.0), 1.0))
	return out

func _sample(image: Image, x: int, y: int, axis: int, offset: float, size: Vector2i) -> Color:
	var u := float(x)
	var v := float(y)
	var o := int(round(offset))
	if axis == 0:
		u = clampf(float(x + o), 0.0, float(size.x - 1))
		v = float(y)
	else:
		u = float(x)
		v = clampf(float(y + o), 0.0, float(size.y - 1))
	return image.get_pixel(int(u), int(v))

## Pass 3 in one blit: the sobel normal, with the shape term from the light
## reference. Materialize's Blit_Normal_From_Height, fragNormal, ported.
func _blit(image: Image, pass_id: int, params: Dictionary) -> Image:
	var size: Vector2i = image.get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)

	for y in range(size.y):
		for x in range(size.x):
			var normal_dir := Vector3(0.0, 0.0, 1.0)

			if pass_id == NormalFromHeight.PASS_NORMAL:
				var base: Color = image.get_pixel(x, y)
				var main_tex := Vector3(base.r, base.g, base.b)
				var right: Color = image.get_pixel(mini(x + 1, size.x - 1), y)
				var down: Color = image.get_pixel(x, mini(y + 1, size.y - 1))
				var contrast := float(params["blur_contrast"])

				# Godot's UV points down, so the vertical slope is the negated
				# screen slope. That is what keeps the sobel normal pointing up
				# out of a flat surface, the same convention as a normal map:
				# a flat source gives (0, 0, 1), stored as 0.5, 0.5, 1.0.
				var slope_x := Vector3(1.0, 0.0, (right.r - base.r) * contrast)
				var slope_y := Vector3(0.0, 1.0, -(down.r - base.r) * contrast)
				var sobel_dir := slope_x.cross(slope_y).normalized()

				# `Shape Recognition` blends the sobel normal with the broad
				# shape built from the light reference: the wide blur erases
				# mid-frequency detail, so the difference between the sharp and
				# the blurred grey is the shape, tilted by `Light Rotation` and
				# centred by `Shape Bias`.
				var light_map: Image = params["light_map"]
				var light_blur_map: Image = params["light_blur"]
				var light: Color = light_map.get_pixel(x, y)
				if params["desaturate"] == 1:
					var grey := light.r * 0.3 + light.g * 0.5 + light.b * 0.2
					light = Color(grey, grey, grey, 1.0)
				var blurred: Color = light_blur_map.get_pixel(x, y)
				var shape_height := (light.r - blurred.r) + float(params["shape_bias"])
				shape_height = shape_height * 2.0 - 1.0

				var rotation := float(params["light_rotation"])
				var light_dir := Vector3(sin(rotation), cos(rotation), 0.0)
				var light_cross := light_dir.cross(Vector3(0.0, 0.0, 1.0))
				var shape: Vector3 = light_dir * shape_height + light_cross * sobel_dir.dot(light_cross)
				shape.z = sqrt(max(1.0 - min(1.0, shape.x * shape.x + shape.y * shape.y), 0.0))
				shape = shape.normalized()
				normal_dir = sobel_dir.lerp(shape, float(params["shape_recognition"])).normalized()

			out.set_pixel(x, y, Color(normal_dir.x * 0.5 + 0.5, normal_dir.y * 0.5 + 0.5,
				normal_dir.z * 0.5 + 0.5, 1.0))
	return out

func _normal_params(settings: Dictionary, contrast: float, source: Image, light_blur: Image) -> Dictionary:
	return {
		"blur_contrast": contrast,
		"desaturate": 1 if settings["use_diffuse"] == true else 0,
		"shape_recognition": clampf(float(settings["shape_recognition"]), 0.0, 1.0),
		"shape_bias": clampf(float(settings["shape_bias"]), 0.0, 1.0),
		"light_rotation": float(settings["light_rotation"]),
		"light_map": source,
		"light_blur": light_blur,
	}

## Pass 5: the six pyramid levels plus the sobel level, re-blended by the
## equalizer weights, then angularity, angular intensity and final contrast.
func _combine(levels: Array, settings: Dictionary) -> Image:
	var size: Vector2i = levels[0].get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	var weights: Array = settings["weights"]
	var intensity := clampf(float(settings["angular_intensity"]), 0.0, 1.0)
	var angularity := clampf(float(settings["angularity"]), 0.0, 1.0)
	var contrast := clampf(float(settings["final_contrast"]), 0.1, 20.0)

	var total_weight := 0.0
	for level in range(LEVELS):
		total_weight += float(weights[level])

	for y in range(size.y):
		for x in range(size.x):
			var sum := Vector3(0.0, 0.0, 0.0)
			for level in range(LEVELS):
				var color: Color = levels[level].get_pixel(x, y)
				sum += Vector3(color.r, color.g, color.b) * float(weights[level])
			var normal_dir: Vector3 = sum / max(total_weight, 0.0001)
			normal_dir = (normal_dir * 2.0 - Vector3(1.0, 1.0, 1.0)).normalized()

			var xy := Vector2(normal_dir.x, normal_dir.y)
			var flat := xy.normalized() if xy.length() > 0.0 else Vector2(0.0, 0.0)
			var angular_dir := Vector3(flat.x * intensity, flat.y * intensity,
				max(1.0 - intensity, 0.001)).normalized()
			normal_dir = normal_dir.lerp(angular_dir, angularity)
			# Unity applies Final Contrast to the un-normalised mix, then
			# normalises once at the end, so the mirror keeps that order.
			normal_dir = Vector3(normal_dir.x * contrast, normal_dir.y * contrast,
				pow(clampf(normal_dir.z, 0.0, 1.0), contrast))
			normal_dir = normal_dir.normalized() * 0.5 + Vector3(0.5, 0.5, 0.5)
			out.set_pixel(x, y, Color(normal_dir.x, normal_dir.y, normal_dir.z, 1.0))
	return out

func _stats(image: Image) -> Dictionary:
	var size: Vector2i = image.get_size()
	var count := float(size.x * size.y)
	var total := 0.0
	var total_r := 0.0
	var total_g := 0.0
	var total_b := 0.0
	var sq := 0.0
	# `tilt` is the mean length of the (red, green) deviation from neutral:
	# how far each normal leans off straight up. A flat source has tilt 0;
	# relief shows as tilt, while `spread` alone mostly tracks the detail in
	# the grey value.
	var tilt := 0.0
	for y in range(size.y):
		for x in range(size.x):
			var color: Color = image.get_pixel(x, y)
			var value := (color.r + color.g + color.b) / 3.0
			total += value
			total_r += color.r
			total_g += color.g
			total_b += color.b
			sq += value * value
			tilt += sqrt((color.r - 0.5) * (color.r - 0.5) + (color.g - 0.5) * (color.g - 0.5))
	var mean := total / count
	return {"mean_r": total_r / count, "mean_g": total_g / count,
		"mean_b": total_b / count, "spread": sqrt(max(sq / count - mean * mean, 0.0)),
		"tilt": tilt / count}

func _spread(image: Image) -> float:
	return _stats(image)["spread"]
