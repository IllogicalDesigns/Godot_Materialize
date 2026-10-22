extends Node2D
## CPU reference implementation of Height From Diffuse. Runs with no GPU and no
## VRAM, so it validates the algorithm on its own:
##
##   godot --headless --quit --path . res://tests/height_cpu.tscn
##
## It reproduces the shader passes in GDScript: the grey base, the raised-cosine
## separable blur pyramid (linear sampling with wrap, matching filter_linear +
## repeat_enable), the wide average map, and the combine math. The point is to
## catch math errors that the GPU runs cannot separate from shader bugs, and to
## have a reference image to compare the GPU result against later.
##
## A flat source must land on 0.500 - that is the check that caught the missing
## +0.5 per level in the combine pass.

const LEVELS := 7

func _ready() -> void:
	var flat := _flat(128, 0.5)
	var flat_result := _pipeline(flat)
	print("flat source -> result ", _stats(flat_result), "   expect min/max/mean all 0.500")

	var stone := TestPattern.stone(Vector2i(128, 128))
	print("stone source -> ", _stats(stone))
	var stone_result := _pipeline(stone)
	print("stone result -> ", _stats(stone_result))

	var dir := "user://height_cpu/"
	DirAccess.make_dir_recursive_absolute(dir)
	var out := stone_result.duplicate()
	out.convert(Image.FORMAT_RGBA8)
	out.save_png(dir + "result.png")
	var src := stone.duplicate()
	src.convert(Image.FORMAT_RGBA8)
	src.save_png(dir + "source.png")
	print("Wrote ", dir, "result.png and source.png")

	# Joint relief check: average the brick centres and the mortar lines.
	var size := stone_result.get_size()
	var brick_width := maxf(float(size.x) / 8.0, 16.0)
	var brick_height := maxf(float(size.y) / 12.0, 12.0)
	var mortar := clampf(brick_width * 0.07, 2.0, 12.0)
	var brick_sum := 0.0
	var brick_count := 0
	var mortar_sum := 0.0
	var mortar_count := 0
	for y in range(size.y):
		for x in range(size.x):
			var local_x := fmod(float(x), brick_width)
			var local_y := fmod(float(y), brick_height)
			var value := stone_result.get_pixel(x, y).r
			if local_x < mortar or local_y < mortar:
				mortar_sum += value
				mortar_count += 1
			elif local_x > brick_width * 0.5 - mortar and local_y > brick_height * 0.5 - mortar:
				brick_sum += value
				brick_count += 1
	print("mortar lines mean %.3f, brick centres mean %.3f, difference %.3f" % [
		mortar_sum / mortar_count, brick_sum / brick_count,
		brick_sum / brick_count - mortar_sum / mortar_count])
	print("expect mortar lower than brick centres (joints read as recessed)")

	get_tree().quit()

func _flat(size: int, value: float) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBAF)
	image.fill(Color(value, value, value, 1.0))
	return image

func _pipeline(source: Image) -> Image:
	var base := _desaturate(source)
	var levels: Array[Image] = [base]
	var size := source.get_size()
	var extra := (float(size.x + size.y) * 0.5) / 1024.0
	var spread := 1.0
	var step := extra

	for _level in range(1, LEVELS):
		var temp := _blur(levels[-1], 0, spread, 4)
		levels.append(_blur(temp, 1, spread, 4))
		spread += step
		step *= 2.0

	var avg_spread := 64.0 * extra
	var avg := _blur(levels[LEVELS - 1], 0, avg_spread, 32)
	avg = _blur(avg, 1, avg_spread, 32)
	return _combine(levels, avg)

func _desaturate(source: Image) -> Image:
	var size := source.get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	for y in range(size.y):
		for x in range(size.x):
			var c := source.get_pixel(x, y)
			var grey := clampf(c.r * 0.3 + c.g * 0.5 + c.b * 0.2, 0.0, 1.0)
			out.set_pixel(x, y, Color(grey, grey, grey, 1.0))
	return out

## One separable axis of the raised-cosine windowed box blur.
func _blur(image: Image, axis: int, spread: float, samples: int) -> Image:
	var size := image.get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	var total := 0.0
	for i in range(-samples, samples + 1):
		total += cos(float(i) / float(samples * 2) * TAU) * 0.5 + 0.5

	for y in range(size.y):
		for x in range(size.x):
			var sum_r := 0.0
			var sum_g := 0.0
			var sum_b := 0.0
			for i in range(-samples, samples + 1):
				var weight := cos(float(i) / float(samples * 2) * TAU) * 0.5 + 0.5
				var c := _sample(image, x, y, axis, float(i) * spread, size)
				sum_r += c.r * weight
				sum_g += c.g * weight
				sum_b += c.b * weight
			var grey := clampf((sum_r / total) * 0.3 + (sum_g / total) * 0.5 + (sum_b / total) * 0.2, 0.0, 1.0)
			var value := clampf((grey - 0.5) * 1.0 + 0.5, 0.0, 1.0)
			out.set_pixel(x, y, Color(value, value, value, 1.0))
	return out

## Linear sampling along one axis with wrap, matching filter_linear + repeat_enable.
func _sample(image: Image, x: int, y: int, axis: int, offset: float, size: Vector2i) -> Color:
	var fx := float(x)
	var fy := float(y)
	if axis == 0:
		fx += offset
	else:
		fy += offset
	var ix := floorf(fx)
	var iy := floorf(fy)
	var wx := fx - ix
	var wy := fy - iy
	# posmod, not %, because % takes the sign of the dividend in GDScript and
	# the blur taps reach outside the image on the negative side.
	var x0 := posmod(int(ix), size.x)
	var x1 := (x0 + 1) % size.x
	var y0 := posmod(int(iy), size.y)
	var y1 := (y0 + 1) % size.y
	var top := image.get_pixel(x0, y0).lerp(image.get_pixel(x1, y0), wx)
	var bottom := image.get_pixel(x0, y1).lerp(image.get_pixel(x1, y1), wx)
	return top.lerp(bottom, wy)

func _combine(levels: Array[Image], avg: Image) -> Image:
	var settings := HeightFromDiffuse.defaults()
	var weights: Array = settings["weights"]
	var contrasts: Array = settings["contrasts"]
	var final_contrast := float(settings["final_contrast"])
	var final_bias := float(settings["final_bias"])
	var gain := HeightFromDiffuse.gain_mapping(float(settings["final_gain"]))

	var size := levels[0].get_size()
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)

	for y in range(size.y):
		for x in range(size.x):
			var avg_value := pow(avg.get_pixel(x, y).r, 0.45)
			var sum := 0.0
			var total := 0.0
			for level in range(LEVELS):
				var contribution := (pow(levels[level].get_pixel(x, y).r, 0.45) - avg_value) \
						* float(contrasts[level]) + 0.5
				sum += contribution * float(weights[level])
				total += float(weights[level])
			var height := sum / total
			height = clampf((height - 0.5) * final_contrast + 0.5 + final_bias, 0.0, 1.0)
			if height > 0.5:
				height = pow(clampf(height * 2.0 - 1.0, 0.0, 1.0), gain) * 0.5 + 0.5
			else:
				height = 1.0 - (pow(clampf((1.0 - height) * 2.0 - 1.0, 0.0, 1.0), gain) * 0.5 + 0.5)
			out.set_pixel(x, y, Color(height, height, height, 1.0))
	return out

func _stats(image: Image) -> String:
	var size := image.get_size()
	var low := 1e9
	var high := -1e9
	var total := 0.0
	for y in range(size.y):
		for x in range(size.x):
			var value := image.get_pixel(x, y).r
			low = minf(low, value)
			high = maxf(high, value)
			total += value
	return "min %.3f max %.3f mean %.3f" % [low, high, total / float(size.x * size.y)]
