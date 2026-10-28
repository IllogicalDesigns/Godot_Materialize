extends Node

## End-to-end check of the AO map pass chain, on the CPU.
## The live test drives the real UI; this file runs the same pass chain the
## real GPU does, through the real `Blit` (headless GPU is available), then
## mirrors every pass on the CPU, pixel by pixel, the way `tests/normal_cpu.gd`
## does. The comparison is on the aggregate stats, not per pixel: the ray hash
## (`rand` in `ao_from_normal.gdshader`) decorrelates between the CPU and the
## GPU, because the GPU's `sin` argument reduction at ~23000 differs from
## `sin` on CPU doubles, so the two runs sample the hemisphere at *different*
## directions. The integral they estimate is the same, so the mean AO and the
## spread agree, the groove occludes more than the plate on both, and the
## height-blend rule moves the mean the same way on both.
##
## The height and normal maps come from the real GPU pass chain (the drivers
## `HeightFromDiffuse` and `NormalFromHeight`), so the CPU mirror sees exactly
## the same inputs the GPU AO pass saw. The AO pass count and sample count are
## shrunk for the CPU loop; the params override is handed to the driver so the
## GPU runs the same counts.
##
## `godot --headless res://tests/ao_cpu.tscn`

const SIZE := 48
const PASSES := 25
const SAMPLES := 10
const RAY_STEPS := 16

var _blit: Blit
var _failures: Array

func _ready() -> void:
	_blit = Blit.new()
	add_child(_blit)
	await _run()
	_quit()

## The GPU pass chain, and the CPU mirror of the same chain.
func _run() -> void:
	var stone: Image = TestPattern.stone(SIZE)
	var height: Image = await HeightFromDiffuse.new().generate(stone, _blit)
	var normal: Image = await NormalFromHeight.new().generate(height, _blit)
	var driver := AOFromNormal.new()
	var params := {"passes": PASSES, "ao_samples": SAMPLES}
	var gpu: Image = await driver.generate(normal, _blit, height, params)

	# The pass chain is a running mean over the hemisphere sample set, so the
	# GPU and CPU maps estimate the same integral with independent random
	# rays. The stats are the comparison.
	var g_mean: float = _mean(gpu)
	var g_std: float = _std(gpu, g_mean)
	var cpu: Image = _ao_cpu(normal, height, driver.settings(), PASSES, SAMPLES, 1.0, 1.0, 0.0)
	var c_mean: float = _mean(cpu)
	var c_std: float = _std(cpu, c_mean)
	_check(absf(g_mean - c_mean) < 0.06, "AO mean: gpu %.3f vs cpu %.3f" % [g_mean, c_mean])
	_check(absf(g_std - c_std) < 0.12, "AO spread: gpu %.3f vs cpu %.3f" % [g_std, c_std])
	_check(gpu.get_size() == Vector2i(SIZE, SIZE) and cpu.get_size() == Vector2i(SIZE, SIZE), "the AO map is %d x %d" % [SIZE, SIZE])
	_check(_min(gpu) >= 0.0 and _max(gpu) <= 1.0, "the AO map is in 0..1 (saturate)")

	# The stone pattern's groove occludes more than the flat plate: on both
	# maps the groove column is darker than the plate column.
	var g_groove: float = _column_mean(gpu, 17)
	var g_plate: float = _column_mean(gpu, 40)
	_check(g_groove < g_plate, "gpu: the groove column is darker than the plate (%.3f vs %.3f)" % [g_groove, g_plate])
	var c_groove: float = _column_mean(cpu, 17)
	var c_plate: float = _column_mean(cpu, 40)
	_check(c_groove < c_plate, "cpu: the groove column is darker than the plate (%.3f vs %.3f)" % [c_groove, c_plate])
	_check(absf(g_groove - c_groove) < 0.10, "groove column: gpu %.3f vs cpu %.3f" % [g_groove, c_groove])
	_check(absf(g_plate - c_plate) < 0.10, "plate column: gpu %.3f vs cpu %.3f" % [g_plate, c_plate])

	# The height blend rule, on both sides: blend 0 ignores the height map,
	# so the plate gets the full sky and the mean rises.
	var gpu2: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "blend": 0.0})
	var cpu2: Image = _ao_cpu(normal, height, driver.settings(), PASSES, SAMPLES, 0.0, 1.0, 0.0)
	_check(_mean(gpu2) > g_mean, "gpu: height blend off raises the mean AO (%.3f -> %.3f)" % [g_mean, _mean(gpu2)])
	_check(_mean(cpu2) > c_mean, "cpu: height blend off raises the mean AO (%.3f -> %.3f)" % [c_mean, _mean(cpu2)])

	# The final grade lives in the combine pass: contrast pushes mid-grey
	# AO darker, bias lifts it. The GPU params dict and the CPU mirror use
	# the same numbers.
	var gpu3: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "final_contrast": 5.0})
	var cpu3: Image = _ao_cpu(normal, height, driver.settings(), PASSES, SAMPLES, 1.0, 5.0, 0.0)
	_check(_mean(gpu3) < g_mean, "gpu: AO Power 5 pushes the mean AO down (%.3f -> %.3f)" % [g_mean, _mean(gpu3)])
	_check(_mean(cpu3) < c_mean, "cpu: AO Power 5 pushes the mean AO down (%.3f -> %.3f)" % [c_mean, _mean(cpu3)])
	_check(absf(_mean(gpu3) - _mean(cpu3)) < 0.06, "AO Power 5 mean: gpu %.3f vs cpu %.3f" % [_mean(gpu3), _mean(cpu3)])

	var gpu4: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "final_bias": 0.3})
	var cpu4: Image = _ao_cpu(normal, height, driver.settings(), PASSES, SAMPLES, 1.0, 1.0, 0.3)
	_check(_mean(gpu4) > g_mean, "gpu: AO Bias 0.3 lifts the mean AO (%.3f -> %.3f)" % [g_mean, _mean(gpu4)])
	_check(_mean(cpu4) > c_mean, "cpu: AO Bias 0.3 lifts the mean AO (%.3f -> %.3f)" % [c_mean, _mean(cpu4)])

# The CPU mirror of the AO chain, pass by pass: a running mean over the
# hemisphere rays, the ray march, the height hit test, the combine pass.
func _ao_cpu(normal: Image, height: Image, settings: Dictionary, passes: int, samples: int, blend: float, contrast: float, bias: float) -> Image:
	var size: Vector2i = normal.get_size()
	var spread: float = settings["spread"]
	var depth: float = settings["depth"]
	var step: float = depth * 0.01
	var acc: Image = normal.duplicate()
	for i in range(1, passes):
		var progress: float = float(i) / float(passes)
		var blend_amount: float = 1.0 / float(i)
		var next := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBF)
		for y in size.y:
			for x in size.x:
				var uv := Vector2((x + 0.5) / size.x, (y + 0.5) / size.y)
				var raw := normal.get_pixel(x, y)
				var sn := Vector3(raw.r * 2.0 - 1.0, raw.g * 2.0 - 1.0, raw.b * 2.0 - 1.0).normalized()
				var sum := 0.0
				for j in samples:
					var seed := Vector3(x + 0.5, y + 0.5, float(i * 7 + j * 13))
					var a := _rand(seed) * TAU
					var b := _rand(seed + Vector3(1, 0, 0)) * PI * 0.5
					b = lerpf(PI * 0.5, b, spread / 100.0)
					b = minf(b, depth / 1000.0)
					var cos_b := cos(b)
					# Godot UV points down, so the ray Y is negated at the
					# frame conversion, the same as the shader.
					var dir := Vector3(cos(a) * cos_b, -sin(b), sin(a) * cos_b)
					var ray := Vector3(uv.x, uv.y, 0.0) + dir * (progress * step)
					var t := progress * step
					var hit := signf(-sn.y)
					var steps := 0
					while hit == 0.0 and steps < RAY_STEPS:
						t += step
						var h := _sample(height, Vector2(ray.x + dir.x * t, ray.y + dir.y * t))
						if h > ray.z:
							hit = 1.0
							break
						steps += 1
					if hit > 0.0:
						var dist := clampf(t / step, 0.0, 1.0)
						sum = lerpf(sum, 1.0 - dist, blend_amount)
				var prev := acc.get_pixel(x, y)
				next.set_pixel(x, y, Color(lerpf(prev.r, sum, blend_amount), lerpf(prev.green, sum, blend_amount), lerpf(prev.blue, sum, blend_amount), 1.0))
		acc = next
	# The combine pass: mix the x/y AO by the height blend, the final grade,
	# and the saturate.
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var a := acc.get_pixel(x, y)
			var ao := lerpf(a.r, a.green, blend) + bias
			var v: float = clampf(powf(maxf(ao, 0.0), contrast), 0.0, 1.0)
			out.set_pixel(x, y, Color(v, v, v, 1.0))
	return out

## Bilinear sampling with the wrap, the way a REPEAT texture sampler samples
## a texture: pixel centres are `(x + 0.5) / size`, and uv wraps into 0..1.
func _sample(img: Image, uv: Vector2) -> float:
	var size: Vector2i = img.get_size()
	var px: float = fmod(uv.x, 1.0) * size.x - 0.5
	if px < 0.0:
		px += float(size.x)
	var py: float = fmod(uv.y, 1.0) * size.y - 0.5
	if py < 0.0:
		py += float(size.y)
	var x0 := int(floor(px))
	var y0 := int(floor(py))
	var fx: float = px - float(x0)
	var fy: float = py - float(y0)
	var c00: float = img.get_pixel(((x0 % size.x) + size.x) % size.x, ((y0 % size.y) + size.y) % size.y).r
	var c10: float = img.get_pixel(((x0 + 1) % size.x + size.x) % size.x, ((y0 % size.y) + size.y) % size.y).r
	var c01: float = img.get_pixel(((x0 % size.x) + size.x) % size.x, ((y0 + 1) % size.y + size.y) % size.y).r
	var c11: float = img.get_pixel(((x0 + 1) % size.x + size.x) % size.x, ((y0 + 1) % size.y + size.y) % size.y).r
	return lerpf(lerpf(c00, c10, fx), lerpf(c01, c11, fx), fy)

func _rand(v: Vector3) -> float:
	return fmod(sin(v.dot(Vector3(12.9898, 78.233, 37.7198))) * 43758.5453, 1.0)

func _mean(image: Image) -> float:
	var total: float = 0.0
	var size: Vector2i = image.get_size()
	for y in size.y:
		for x in size.x:
			total += image.get_pixelv(Vector2i(x, y)).r
	return total / float(size.x * size.y)

func _std(image: Image, mean: float) -> float:
	var total: float = 0.0
	var size: Vector2i = image.get_size()
	for y in size.y:
		for x in size.x:
			var d: float = image.get_pixelv(Vector2i(x, y)).r - mean
			total += d * d
	return sqrt(total / float(size.x * size.y))

func _min(image: Image) -> float:
	var lowest := 1.0
	for y in image.get_size().y:
		for x in image.get_size().x:
			lowest = minf(lowest, image.get_pixelv(Vector2i(x, y)).r)
	return lowest

func _max(image: Image) -> float:
	var highest := 0.0
	for y in image.get_size().y:
		for x in image.get_size().x:
			highest = maxf(highest, image.get_pixelv(Vector2i(x, y)).r)
	return highest

func _column_mean(image: Image, x: int) -> float:
	var total: float = 0.0
	for y in image.get_size().y:
		total += image.get_pixelv(Vector2i(x, y)).r
	return total / float(image.get_size().y)

func _check(condition: bool, what: String) -> void:
	if not condition:
		_fail(what)

func _fail(what: String) -> void:
	_failures.append("FAIL: " + what)
	push_error(what)

func _quit() -> void:
	print("AO map CPU: %d x %d, %d passes, %d samples" % [SIZE, SIZE, PASSES, SAMPLES])
	for f in _failures:
		print(f)
	if _failures.size() == 0:
		print("all checks pass")
	else:
		print("%d failures" % _failures.size())
	get_tree().quit(_failures.size() == 0)
