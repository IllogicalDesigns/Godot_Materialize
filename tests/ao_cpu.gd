extends Node

## End-to-end check of the AO map pass chain, on the CPU.
## The live test drives the real UI; this file runs the same pass chain the
## real GPU does, through the real `Blit`, then mirrors every pass on the CPU,
## pixel by pixel, the way `tests/normal_cpu.gd` does.
##
## The mirror is the cone sweep of `ao_from_normal.gdshader` pass 1: the
## direction turns by `progress`, `samples` cone points walk the cone, the
## normal term is the weighted dot product, the depth term is the best
## occlusion found, and the pass result is lerped into the accumulator by
## `1 / i` — the running mean Unity runs 100 times. The combine pass mixes
## the accumulator's red (normal AO) and green (depth AO) by the blend, adds
## the bias, raises to the power, and saturates.
##
## The comparison is on aggregate stats, not per pixel: the randomizer hash
## (`rand` in `ao_from_normal.gdshader`, a sin fract hash) decorrelates
## between the CPU and the GPU, because the GPU's `sin` argument reduction
## differs from `sin` on CPU doubles, so the two runs jitter the cone at
## *different* offsets. The integral they estimate is the same, so the mean
## AO and the spread agree, the groove column occludes more than the plate
## column on both, and the height-blend rule moves the mean the same way on
## both.
##
## The height and normal maps come from the real GPU pass chain (the drivers
## `HeightFromDiffuse` and `NormalFromHeight`), so the CPU mirror sees exactly
## the same inputs the GPU AO pass saw. The AO pass count and sample count are
## shrunk for the CPU loop; the params override is handed to the driver so the
## GPU runs the same counts.
##
## A real display is required, like every Blit run:
##   env DISPLAY=:1 godot --path . res://tests/ao_cpu.tscn

const SIZE := 32
const PASSES := 12
const SAMPLES := 6
# Columns scaled from the live test (512 px, brick width 64): 16 = the mortar
# joint line (even rows), 18 = the brick face beside it.
const GROOVE_X := 16
const PLATE_X := 18

var _blit: Blit
var _failures: Array

func _ready() -> void:
	_blit = Blit.new()
	add_child(_blit)
	await _run()
	_quit()

## The GPU pass chain, and the CPU mirror of the same chain.
func _run() -> void:
	var stone: Image = TestPattern.stone(Vector2i(SIZE, SIZE))
	var height: Image = await HeightFromDiffuse.new().generate(stone, _blit)
	var normal: Image = await NormalFromHeight.new().generate(height, _blit)
	var driver := AOFromNormal.new()
	var params := {"passes": PASSES, "ao_samples": SAMPLES}
	var gpu: Image = await driver.generate(normal, _blit, height, params)

	# The pass chain is a running mean over the cone sample set, so the GPU and
	# CPU maps estimate the same integral with independent randomizers. The
	# stats are the comparison.
	var g_mean: float = _mean(gpu)
	var g_std: float = _std(gpu, g_mean)
	var cpu: Image = _ao_cpu(normal, height, driver.settings, PASSES, SAMPLES, 1.0, 1.0, 0.0)
	var c_mean: float = _mean(cpu)
	var c_std: float = _std(cpu, c_mean)
	_check(absf(g_mean - c_mean) < 0.12, "AO mean: gpu %.3f vs cpu %.3f (tolerance 0.12)" % [g_mean, c_mean])
	_check(absf(g_std - c_std) < 0.12, "AO spread: gpu %.3f vs cpu %.3f" % [g_std, c_std])
	_check(gpu.get_size() == Vector2i(SIZE, SIZE) and cpu.get_size() == Vector2i(SIZE, SIZE), "the AO map is %d x %d" % [SIZE, SIZE])
	_check(_min(gpu) >= 0.0 and _max(gpu) <= 1.0, "the AO map is in 0..1 (saturate)")

	# The stone pattern's mortar column occludes more than the brick face: on
	# both maps the groove column is darker than the plate column.
	var g_groove: float = _column_mean(gpu, GROOVE_X)
	var g_plate: float = _column_mean(gpu, PLATE_X)
	_check(g_groove < g_plate, "gpu: the groove column is darker than the plate (%.3f vs %.3f)" % [g_groove, g_plate])
	var c_groove: float = _column_mean(cpu, GROOVE_X)
	var c_plate: float = _column_mean(cpu, PLATE_X)
	_check(c_groove < c_plate, "cpu: the groove column is darker than the plate (%.3f vs %.3f)" % [c_groove, c_plate])
	_check(absf(g_groove - c_groove) < 0.15, "groove column: gpu %.3f vs cpu %.3f" % [g_groove, c_groove])
	_check(absf(g_plate - c_plate) < 0.15, "plate column: gpu %.3f vs cpu %.3f" % [g_plate, c_plate])

	# The height blend rule, on both sides: blend 0 ignores the height map,
	# so the depth term drops out and the mean rises (the probe measured the
	# normal AO curve above the blended map on the stone wall).
	var gpu2: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "blend": 0.0})
	var cpu2: Image = _ao_cpu(normal, height, driver.settings, PASSES, SAMPLES, 0.0, 1.0, 0.0)
	_check(_mean(gpu2) > g_mean, "gpu: height blend off raises the mean AO (%.3f -> %.3f)" % [g_mean, _mean(gpu2)])
	_check(_mean(cpu2) > c_mean, "cpu: height blend off raises the mean AO (%.3f -> %.3f)" % [c_mean, _mean(cpu2)])

	# The final grade lives in the combine pass: contrast pushes mid-grey AO
	# darker, bias lifts it. The accumulator is random, so the power comparison
	# keeps the same aggregate tolerance as the base mean.
	var gpu3: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "final_contrast": 5.0})
	var cpu3: Image = _ao_cpu(normal, height, driver.settings, PASSES, SAMPLES, 1.0, 5.0, 0.0)
	_check(_mean(gpu3) < g_mean, "gpu: AO Power 5 pushes the mean AO down (%.3f -> %.3f)" % [g_mean, _mean(gpu3)])
	_check(_mean(cpu3) < c_mean, "cpu: AO Power 5 pushes the mean AO down (%.3f -> %.3f)" % [c_mean, _mean(cpu3)])
	_check(absf(_mean(gpu3) - _mean(cpu3)) < 0.15, "AO Power 5 mean: gpu %.3f vs cpu %.3f" % [_mean(gpu3), _mean(cpu3)])

	var gpu4: Image = await driver.generate(normal, _blit, height, {"passes": PASSES, "ao_samples": SAMPLES, "final_bias": 0.3})
	var cpu4: Image = _ao_cpu(normal, height, driver.settings, PASSES, SAMPLES, 1.0, 1.0, 0.3)
	_check(_mean(gpu4) > g_mean, "gpu: AO Bias 0.3 lifts the mean AO (%.3f -> %.3f)" % [g_mean, _mean(gpu4)])
	_check(_mean(cpu4) > c_mean, "cpu: AO Bias 0.3 lifts the mean AO (%.3f -> %.3f)" % [c_mean, _mean(cpu4)])
	print("gpu %.3f mean, std %.3f | cpu %.3f mean, std %.3f" % [g_mean, g_std, c_mean, c_std])
	print("groove %.3f vs plate %.3f (gpu), %.3f vs %.3f (cpu)" % [g_groove, g_plate, c_groove, c_plate])
	print("blend off: gpu %.3f, cpu %.3f | AO Power 5: gpu %.3f, cpu %.3f | AO Bias 0.3: gpu %.3f, cpu %.3f" %
			[_mean(gpu2), _mean(cpu2), _mean(gpu3), _mean(cpu3), _mean(gpu4), _mean(cpu4)])

# The CPU mirror of the AO chain, pass by pass: the cone sweep, the AO.x curve,
# the AO.y occlusion max, the running mean, the combine pass.
func _ao_cpu(normal: Image, height: Image, settings: Dictionary, passes: int, samples: int, blend: float, contrast: float, bias: float) -> Image:
	var size: Vector2i = normal.get_size()
	var spread: float = settings["spread"]
	var depth: float = settings["depth"]
	var texel := Vector2(1.0 / float(size.x), 1.0 / float(size.y))
	# Unity's blend texture starts black, so the accumulator starts as flat
	# black: red is AO.x, green is AO.y.
	var acc := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBF)
	acc.fill(Color(0.0, 0.0, 0.0, 1.0))
	for i in range(1, passes):
		var progress: float = float(i) / float(passes)
		var blend_amount: float = 1.0 / float(i)
		# Unity lines 371-372, the cone direction for this pass.
		var direction := Vector2(sin(progress * TAU), cos(progress * TAU))
		var next := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBF)
		for y in size.y:
			for x in size.x:
				var uv := Vector2((x + 0.5) / size.x, (y + 0.5) / size.y)
				var main_tex := _decode(_sample_rgb(normal, uv))
				var main_height: float = _sample_g(height, uv)
				var ao_x: float = 0.0
				var weight: float = 0.0
				var ao_y: float = 0.0
				for j in range(1, samples + 1):
					var prog: float = float(j) / float(samples)
					# Unity lines 377-378, the per-sample randomizer inside the
					# cone. The seeds are unrelated to the GPU's, so the runs
					# jitter the cone at different offsets.
					var seed := Vector3(x + 0.5, y + 0.5, float(i * 100 + j))
					var randomizer := Vector2(_rand(seed), _rand(Vector3(seed.z, seed.x, seed.y))) * prog * 0.1
					var uv_offset := direction * spread * prog + randomizer
					var true_dir: Vector2 = _norm2(uv_offset)
					var sample_uv := uv + texel * uv_offset
					var sample_tex := _decode(_sample_rgb(normal, sample_uv))
					var sample_height: float = _sample_g(height, sample_uv)
					# Unity lines 387-389, the normal term.
					var importance: float = sqrt(1.0 - prog)
					ao_x += (sample_tex.x * true_dir.x + sample_tex.y * true_dir.y) * importance
					weight += importance
					# Unity lines 391-394, the depth term.
					var sample_pos := Vector3(true_dir.x * spread * prog, true_dir.y * spread * prog,
							(sample_height - main_height) * depth)
					var dist: float = clampf(sample_pos.length() * 0.1, 0.0, 1.0)
					var l: float = sample_pos.length()
					var ao_sample: float = 0.0
					if l > 1e-5:
						ao_sample = clampf(sample_pos.z / l, 0.0, 1.0) * dist
					ao_y = maxf(ao_sample, ao_y)
				ao_x /= maxf(weight, 1e-5)
				# Unity lines 400-404, the AO.x curve.
				var v: float = pow(clampf(ao_x + 1.0, 0.0, 1.0), 5.0) * pow(clampf(ao_x + 0.5, 0.0, 1.0), 0.2)
				ao_x = sqrt(v)
				ao_y = 1.0 - ao_y
				# Unity line 409, the running mean into the accumulator.
				var prev := acc.get_pixel(x, y)
				next.set_pixel(x, y, Color(lerpf(prev.r, ao_x, blend_amount), lerpf(prev.g, ao_y, blend_amount), 0.0, 1.0))
		acc = next
	# The combine pass: mix the x/y AO by the height blend, the final grade,
	# and the saturate.
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var a := acc.get_pixel(x, y)
			var ao := lerpf(a.r, a.g, blend) + bias
			var v: float = clampf(pow(maxf(ao, 0.0), contrast), 0.0, 1.0)
			out.set_pixel(x, y, Color(v, v, v, 1.0))
	return out

## The stored normal, signed 0.5 neutral, decoded to tangent space and flipped
## into the Y-up frame Unity samples in (Godot UV points down).
func _decode(n: Vector3) -> Vector3:
	var v := Vector3(n.x * 2.0 - 1.0, -(n.y * 2.0 - 1.0), n.z * 2.0 - 1.0)
	if v.length() < 1e-5:
		return Vector3(0.0, 0.0, 1.0)
	return v.normalized()

func _norm2(v: Vector2) -> Vector2:
	if v.length() < 1e-5:
		return Vector2.ZERO
	return v.normalized()

## Bilinear sampling with the wrap, the way a REPEAT texture sampler samples a
## texture: pixel centres are `(x + 0.5) / size`, and uv wraps into 0..1.
func _sample_uv(img: Image, uv: Vector2) -> Vector2:
	var size: Vector2i = img.get_size()
	var px: float = fmod(uv.x, 1.0) * size.x - 0.5
	if px < 0.0:
		px += float(size.x)
	var py: float = fmod(uv.y, 1.0) * size.y - 0.5
	if py < 0.0:
		py += float(size.y)
	return Vector2(floor(px), floor(py))

func _sample_rgb(img: Image, uv: Vector2) -> Vector3:
	var size: Vector2i = img.get_size()
	var c := _sample_uv(img, uv)
	var x0 := int(c.x)
	var y0 := int(c.y)
	var fx: float = c.x + 0.5 - float(x0)
	var fy: float = c.y + 0.5 - float(y0)
	var c00 := img.get_pixel(((x0 % size.x) + size.x) % size.x, ((y0 % size.y) + size.y) % size.y)
	var c10 := img.get_pixel(((x0 + 1) % size.x + size.x) % size.x, ((y0 % size.y) + size.y) % size.y)
	var c01 := img.get_pixel(((x0 % size.x) + size.x) % size.x, ((y0 + 1) % size.y + size.y) % size.y)
	var c11 := img.get_pixel(((x0 + 1) % size.x + size.x) % size.x, ((y0 + 1) % size.y + size.y) % size.y)
	var top := c00.lerp(c10, fx)
	var bottom := c01.lerp(c11, fx)
	return Vector3(top.r, top.g, top.b).lerp(Vector3(bottom.r, bottom.g, bottom.b), fy)

func _sample_g(img: Image, uv: Vector2) -> float:
	return _sample_rgb(img, uv).y

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
	get_tree().quit(_failures.size())
