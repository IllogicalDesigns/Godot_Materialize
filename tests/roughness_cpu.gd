extends Node
# CPU mirror of MapModules/roughnessMap/roughness_from_diffuse.gdshader, the BLUR
# pair and the ROUGHNESS pass. The GPU chain must equal the CPU chain.
#
# fragSmoothness marks pixels CLOSE to each colour swatch, runs each mark
# through its Low/High smoothstep, lerps the regions towards their roughness,
# multiplies the high pass overlay onto the result, and writes `1 - smoothness`
# so the map is roughness. The source is `TestPattern.stone`, the warm brick
# wall the suite uses, with a bright steel plate painted on it: the colour
# "Pick Color" finds on a smooth region.
#
# Every level is roughness, so the CPU mirrors Unity's smoothness-space order
# (base -> sample 2 -> sample 1 -> metal) and inverts at the end, exactly as
# the shader does.
#
# Run: DISPLAY=:1 godot --path . res://tests/roughness_cpu.tscn

const SIZE := 256
const GREY := Vector3(0.3, 0.5, 0.2)
const STEEL := Color(0.80, 0.82, 0.86)
const BRICK := Color(0.45, 0.22, 0.17)
const PLATE := Rect2i(153, 56, 66, 41)
const DELTA := 0.03

var failures := 0

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var source := _make_source()
	var params := RoughnessFromDiffuse.defaults()
	# Sample 1's swatch is the plate's steel, sample 2's is the brick's brown,
	# and both regions are switched on.
	params["sample_color1"] = STEEL
	params["sample_color2"] = BRICK
	params["use_sample1"] = true
	params["use_sample2"] = true

	await _check_chain(source, blit, params)
	await _check_mask_edges(source, blit, params)
	await _check_overlay(source, blit, params)
	await _check_blur_size(source, blit, params)
	await _check_metal_coupling(source, blit, params)
	await _check_isolate(source, blit, params)
	await _check_reveal_is_preview_only(source, blit, params)
	await _check_panel_rows(source, blit)

	if failures == 0:
		print("roughness cpu reference: all checks passed")
	else:
		print("ROUGHNESS CPU TEST FAILED, see messages above")
	get_tree().quit(1 if failures > 0 else 0)

func fail(msg: String) -> void:
	failures += 1
	print("FAIL: " + msg)

func probe(plate: bool) -> Vector2i:
	# Inside the plate, and on a brick well away from it.
	return Vector2i(PLATE.position.x + 33, PLATE.position.y + 20) if plate else Vector2i(40, 200)

func _make_source() -> Image:
	var img := TestPattern.stone(Vector2i(SIZE, SIZE))
	for y in range(PLATE.position.y, PLATE.position.y + PLATE.size.y):
		for x in range(PLATE.position.x, PLATE.position.x + PLATE.size.x):
			img.set_pixel(x, y, STEEL)
	return img

# The shader's rgb_to_hsl (Photoshop.cginc), same saturation and hue maths.
func rgb_to_hsl(c: Color) -> Vector3:
	var fmin := minf(minf(c.r, c.g), c.b)
	var fmax := maxf(maxf(c.r, c.g), c.b)
	var delta := fmax - fmin
	var hsl := Vector3(0.0, 0.0, (fmax + fmin) * 0.5)
	if delta == 0.0:
		return hsl
	if hsl.z < 0.5:
		hsl.y = delta / (fmax + fmin)
	else:
		hsl.y = delta / (2.0 - fmax - fmin)
	var delta_r := (((fmax - c.r) / 6.0) + (delta * 0.5)) / delta
	var delta_g := (((fmax - c.g) / 6.0) + (delta * 0.5)) / delta
	var delta_b := (((fmax - c.b) / 6.0) + (delta * 0.5)) / delta
	if c.r == fmax:
		hsl.x = delta_b - delta_g
	elif c.g == fmax:
		hsl.x = (1.0 / 3.0) + delta_r - delta_b
	elif c.b == fmax:
		hsl.x = (2.0 / 3.0) + delta_g - delta_r
	if hsl.x < 0.0:
		hsl.x += 1.0
	elif hsl.x > 1.0:
		hsl.x -= 1.0
	return hsl

# BLUR pass, the same taps the shader takes: integer offsets, raised cosine
# window, zero at the ends, wrap addressing. Unity's `_BlurSpread` is 1.0 for
# the Smoothness tool, so one tap is one pixel.
func blur_cpu(src: Image, axis: int, size: int) -> Image:
	var out := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	var radius := maxf(float(size), 1.0)
	for y in SIZE:
		for x in SIZE:
			var acc := Color(0.0, 0.0, 0.0, 0.0)
			var weight_sum := 0.0
			for i in range(-size, size + 1):
				if absf(float(i)) > radius:
					continue
				var w := cos(float(i) / radius * PI) * 0.5 + 0.5
				var px := posmod(x + i, SIZE) if axis == 0 else x
				var py := y if axis == 0 else posmod(y + i, SIZE)
				weight_sum += w
				acc += src.get_pixel(px, py) * w
			out.set_pixel(x, y, acc / maxf(weight_sum, 0.0001))
	return out

# Sample mask, Unity's `sample1Mask` / `sample2Mask`: closeness to one swatch,
# weighted by the Hue / Sat / Lum faders, then the Low / High smoothstep. The
# distances are measured on the blur map, the way Unity measures them.
func sample_mask_cpu(blur_map: Image, swatch: Color, low: float, high: float,
		weights: Vector3) -> Image:
	var out := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	var sw_hsl := rgb_to_hsl(swatch)
	var divisor := maxf(weights.x + weights.y + weights.z, 0.0001)
	for y in SIZE:
		for x in SIZE:
			var c_hsl := rgb_to_hsl(blur_map.get_pixel(x, y))
			var hue_dif := 1.0 - minf(minf(absf(c_hsl.x - sw_hsl.x),
					absf((c_hsl.x + 1.0) - sw_hsl.x)),
					absf((c_hsl.x - 1.0) - sw_hsl.x)) * 2.0
			var sat_dif := 1.0 - absf(c_hsl.y - sw_hsl.y)
			var lum_dif := 1.0 - absf(c_hsl.z - sw_hsl.z)
			var mark := (hue_dif * weights.x + sat_dif * weights.y + lum_dif * weights.z) / divisor
			var value := smoothstep(low, high, mark)
			out.set_pixel(x, y, Color(value, value, value, 1.0))
	return out

# ROUGHNESS pass, fragSmoothness in Unity's smoothness space, then the inverted
# write. `sampleN` keys are the panel's keys, so the settings dict the driver
# reads is the same dict the CPU reads.
func roughness_cpu(source: Image, blur_map: Image, overlay_map: Image,
		metal_map: Image, s: Dictionary) -> Image:
	var out := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	var mask1 := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	var mask2 := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	# The shader computes a mask only inside `if (use_sampleN)`, so a sample
	# that is off marks nothing.
	if bool(s["use_sample1"]):
		mask1 = sample_mask_cpu(blur_map, s["sample_color1"],
				float(s["mask_low1"]), float(s["mask_high1"]),
				Vector3(float(s["hue_weight1"]), float(s["sat_weight1"]), float(s["lum_weight1"])))
	if bool(s["use_sample2"]):
		mask2 = sample_mask_cpu(blur_map, s["sample_color2"],
				float(s["mask_low2"]), float(s["mask_high2"]),
				Vector3(float(s["hue_weight2"]), float(s["sat_weight2"]), float(s["lum_weight2"])))
	for y in SIZE:
		for x in SIZE:
			# Unity's lerp order, `Blit_Smoothness.shader` lines 120-123: base,
			# then sample 2, then sample 1, then metal.
			var smoothness := 1.0 - clampf(float(s["base_roughness"]), 0.0, 1.0)
			smoothness = lerp(smoothness, 1.0 - clampf(float(s["sample2_roughness"]), 0.0, 1.0),
					mask2.get_pixel(x, y).r)
			smoothness = lerp(smoothness, 1.0 - clampf(float(s["sample1_roughness"]), 0.0, 1.0),
					mask1.get_pixel(x, y).r)
			smoothness = lerp(smoothness, 1.0 - clampf(float(s["metal_roughness"]), 0.0, 1.0),
					metal_map.get_pixel(x, y).r)
			# Final Contrast and Final Bias, then the high pass overlay
			# multiplies the level, Unity's line 126.
			smoothness = clampf((smoothness - 0.5) * float(s["final_contrast"])
					+ 0.5 + float(s["final_bias"]), 0.0, 1.0)
			var main_c := source.get_pixel(x, y)
			var o := overlay_map.get_pixel(x, y)
			smoothness *= clampf(Vector3(main_c.r - o.r, main_c.g - o.g, main_c.b - o.b).dot(GREY)
					* float(s["blur_overlay"]) + 1.0, 0.0, 10.0)
			smoothness = clampf(smoothness, 0.0, 1.0)
			# "Isolate Mask" paints the mask itself, Unity's lines 129-135.
			if bool(s["isolate_sample1"]):
				smoothness = mask1.get_pixel(x, y).r
			if bool(s["isolate_sample2"]):
				smoothness = mask2.get_pixel(x, y).r
			var rough := 1.0 - smoothness
			out.set_pixel(x, y, Color(rough, rough, rough, 1.0))
	return out

# The CPU chain, the passes the driver runs in order. Blur Size 0 copies the
# source, Unity's early `Graphics.Blit` (`SmoothnessGui.cs` lines 783-797).
func cpu_chain(source: Image, s: Dictionary, metal_map: Image) -> Image:
	var base: Image = source.duplicate()
	var blur_size := int(round(float(s["blur_size"])))
	if blur_size > 0:
		base = blur_cpu(base, 0, blur_size)
		base = blur_cpu(base, 1, blur_size)
	var overlay_size := int(round(float(s["overlay_blur_size"])))
	var overlay: Image = source.duplicate()
	overlay = blur_cpu(overlay, 0, overlay_size)
	overlay = blur_cpu(overlay, 1, overlay_size)
	return roughness_cpu(source, base, overlay, metal_map, s)

func chain_delta(source: Image, blit: Blit, s: Dictionary, metal_map: Image) -> float:
	var gpu := await RoughnessFromDiffuse.new().generate(source, blit, source, metal_map, s)
	var cpu := cpu_chain(source, s, metal_map)
	var worst := 0.0
	for y in range(0, SIZE, 4):
		for x in range(0, SIZE, 4):
			worst = maxf(worst, absf(gpu.get_pixel(x, y).r - cpu.get_pixel(x, y).r))
	return worst

func _check_chain(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var gpu_overlay := await blit.blit(Blit.to_float(source),
			RoughnessFromDiffuse.new()._blur_params(Vector2(1.0, 0.0), 30.0))
	gpu_overlay = await blit.blit(gpu_overlay,
			RoughnessFromDiffuse.new()._blur_params(Vector2(0.0, 1.0), 30.0))
	var cpu_overlay := blur_cpu(blur_cpu(source, 0, 30), 1, 30)
	for q in [Vector2i(40, 200), Vector2i(8, 8), Vector2i(186, 76)]:
		var g := gpu_overlay.get_pixel(q.x, q.y)
		var c := cpu_overlay.get_pixel(q.x, q.y)
		print("overlay (%d,%d) gpu %.4f %.4f %.4f cpu %.4f %.4f %.4f" % [q.x, q.y, g.r, g.g, g.b, c.r, c.g, c.b])
	var gpu_dbg := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, params)
	var cpu_dbg := cpu_chain(source, params, flat)
	for p in [probe(true), probe(false), Vector2i(8, 8), Vector2i(250, 250), Vector2i(120, 40)]:
		print("probe (%d,%d) gpu %.4f cpu %.4f" % [p.x, p.y, gpu_dbg.get_pixel(p.x, p.y).r, cpu_dbg.get_pixel(p.x, p.y).r])
	var worst := await chain_delta(source, blit, params, flat)
	print("full chain, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU roughness map differs from the CPU chain by %.5f" % worst)
	# Sample 1's swatch is the plate's steel, sample 2's is the brick's brown,
	# so the map must split along the plate: the plate is sample 1's smooth
	# level, the wall sits in the middle at base.
	var plate_rough := gpu_dbg.get_pixel(probe(true).x, probe(true).y).r
	var wall_rough := gpu_dbg.get_pixel(probe(false).x, probe(false).y).r
	print("plate roughness %.3f, wall roughness %.3f" % [plate_rough, wall_rough])
	if plate_rough >= wall_rough:
		fail("the steel plate, sample 1's smooth swatch, must be smoother than the wall (%.3f vs %.3f)" % [plate_rough, wall_rough])

func _check_mask_edges(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var wall := probe(false)
	var plate := probe(true)
	# Sample 2's swatch is the brick's brown, so the wall is marked by sample 2
	# and the plate, steel, is not. Narrowing sample 2's High fader drives the
	# wall's mark to 1, so the wall lands fully on sample 2's level, which is
	# smoother than base: roughness falls.
	var tight: Dictionary = params.duplicate()
	tight["mask_high2"] = 0.2
	var floored: Dictionary = params.duplicate()
	floored["mask_low2"] = 0.55
	var a := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, params)
	var b := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, tight)
	var c := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, floored)
	var wall_default := a.get_pixel(wall.x, wall.y).r
	var wall_tight := b.get_pixel(wall.x, wall.y).r
	var wall_floored := c.get_pixel(wall.x, wall.y).r
	print("wall roughness: %.3f default, %.3f with sample 2 High 0.2, %.3f with sample 2 Low 0.55" % [wall_default, wall_tight, wall_floored])
	if wall_tight >= wall_default:
		fail("narrowing sample 2's smoothstep to High 0.2 did not push the wall fully onto its smoother level")
	if wall_floored <= wall_default:
		fail("raising sample 2's smoothstep floor to Low 0.55 cut the wall's mark, so the wall should move back towards Base Roughness 0.9")
	# The plate IS sample 1's swatch, so its mark is 1: the plate sits on
	# sample 1's level, scaled by the High Pass Overlay gain, not on base.
	var plate_rough := a.get_pixel(plate.x, plate.y).r
	print("plate roughness %.3f, sample 1's level is 0.5, base is 0.9" % plate_rough)
	if absf(plate_rough - float(params["sample1_roughness"])) > 0.06:
		fail("the plate, sample 1's swatch, did not land on sample 1's roughness (%.3f, expected about %.3f)" % [plate_rough, float(params["sample1_roughness"])])
	# The plate IS sample 1's swatch, so sample 1 marks it hard; the brown wall
	# is a long way from the steel in hue, so its mark is weaker. Switching
	# sample 1 off must move the plate far more than the wall.
	var off1: Dictionary = params.duplicate()
	off1["use_sample1"] = false
	var d := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, off1)
	var plate_move := absf(d.get_pixel(plate.x, plate.y).r - plate_rough)
	var wall_move := absf(d.get_pixel(wall.x, wall.y).r - wall_default)
	print("switching sample 1 off moves the plate %.3f, the wall %.3f" % [plate_move, wall_move])
	if plate_move <= wall_move:
		fail("sample 1's steel swatch marks the brown wall harder than the plate, its own colour")

func _check_overlay(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var wall := probe(false)
	var off: Dictionary = params.duplicate()
	off["blur_overlay"] = 0.0
	var strong: Dictionary = params.duplicate()
	strong["blur_overlay"] = 6.0
	var a := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, off)
	var b := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, strong)
	var a_wall := a.get_pixel(wall.x, wall.y).r
	var b_wall := b.get_pixel(wall.x, wall.y).r
	print("wall roughness: %.3f with High Pass Overlay 0, %.3f with High Pass Overlay 6" % [a_wall, b_wall])
	if absf(a_wall - b_wall) < 0.01:
		fail("the High Pass Overlay slider did not change the map, it multiplies the level")
	# The overlay multiplies smoothness, so a stronger overlay lifts smoothness
	# and lowers roughness. Unity's default, 3, sits between the two.
	var mid: Dictionary = params.duplicate()
	var m := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, mid)
	var m_wall := m.get_pixel(wall.x, wall.y).r
	print("wall roughness at Unity's High Pass Overlay 3: %.3f" % m_wall)
	# The gain is monotonic, so 3 must land between the 0 and 6 results.
	if a_wall < b_wall:
		if not (a_wall <= m_wall and m_wall <= b_wall):
			fail("the overlay gain is monotonic, 3 must sit between 0 and 6 (%.3f, %.3f, %.3f)" % [a_wall, m_wall, b_wall])
	else:
		if not (b_wall <= m_wall and m_wall <= a_wall):
			fail("the overlay gain is monotonic, 3 must sit between 0 and 6 (%.3f, %.3f, %.3f)" % [a_wall, m_wall, b_wall])

func _check_blur_size(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var sharp: Dictionary = params.duplicate()
	sharp["blur_size"] = 0.0
	var blurred: Dictionary = params.duplicate()
	blurred["blur_size"] = 30.0
	var worst := await chain_delta(source, blit, sharp, flat)
	print("Sample Blur Size 0, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU differs from the CPU chain at Blur Size 0 by %.5f" % worst)
	worst = await chain_delta(source, blit, blurred, flat)
	print("Sample Blur Size 30, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU differs from the CPU chain at Blur Size 30 by %.5f" % worst)
	# Softening the colour bleeds the plate's steel onto the wall, so a pixel
	# just off the plate scores closer to sample 1's swatch and gets smoother.
	var a := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, sharp)
	var b := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, blurred)
	var edge := Vector2i(PLATE.position.x - 6, PLATE.position.y + 20)
	var a_edge := a.get_pixel(edge.x, edge.y).r
	var b_edge := b.get_pixel(edge.x, edge.y).r
	print("just off the plate: roughness %.3f at Blur Size 0, %.3f at Blur Size 30" % [a_edge, b_edge])
	if b_edge >= a_edge:
		fail("blurring did not spread sample 1's smooth region onto the wall, the plate's steel should reach %.3f" % a_edge)

func _check_metal_coupling(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var wall := probe(false)
	var settings := RoughnessFromDiffuse.defaults()
	# Unity's `_DefaultMetallicMap` (`SmoothnessGui.cs` lines 645-683): with no
	# metallic map, the box hands over a flat black texture, so no pixel is
	# metal. The driver passes `Blit.flat(size, 0.0)` for the same reason.
	var flat := Blit.flat(source.get_size(), 0.0)
	var all_metal := Blit.flat(source.get_size(), 1.0)
	# Metal Roughness 0.3, Unity's MetalSmoothness 0.7. Both colour samples are
	# switched off and High Pass Overlay is 0, so the wall reads the metal level
	# straight: a full-metal map puts every pixel on 0.3, a flat map leaves base
	# 0.9.
	var metal_level: Dictionary = params.duplicate()
	metal_level["metal_roughness"] = 0.3
	metal_level["blur_overlay"] = 0.0
	metal_level["use_sample1"] = false
	metal_level["use_sample2"] = false
	var a := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, metal_level)
	var b := await RoughnessFromDiffuse.new().generate(source, blit, source, all_metal, metal_level)
	var a_wall := a.get_pixel(wall.x, wall.y).r
	var b_wall := b.get_pixel(wall.x, wall.y).r
	print("wall roughness with High Pass Overlay 0: %.3f with the flat metallic map, %.3f with a full-metal map" % [a_wall, b_wall])
	if absf(a_wall - 0.9) > 0.05:
		fail("with no metal, the wall should sit on Base Roughness 0.9, got %.3f" % a_wall)
	if absf(b_wall - 0.3) > 0.05:
		fail("a full-metal map should put the wall on Metal Roughness 0.3, got %.3f" % b_wall)
	if b_wall >= a_wall:
		fail("the metallic map did not move the wall, metal is smoother than base here")
	var cpu_b := cpu_chain(source, metal_level, all_metal).get_pixel(wall.x, wall.y).r
	if absf(b_wall - cpu_b) > DELTA:
		fail("the GPU metal region differs from the CPU chain by %.5f" % absf(b_wall - cpu_b))
	# The Metallic map the driver is given is the map store's, so a map of the
	# wrong size must fall back to Unity's flat default.
	var small := Blit.flat(Vector2i(64, 64), 1.0)
	var c := await RoughnessFromDiffuse.new().generate(source, blit, source, small, metal_level)
	if absf(c.get_pixel(wall.x, wall.y).r - a_wall) > 0.001:
		fail("a metallic map of the wrong size is not Unity's flat default, it changed the map")
	# Passing no metallic map at all is Unity's other default path.
	var d := await RoughnessFromDiffuse.new().generate(source, blit, source, null, metal_level)
	if absf(d.get_pixel(wall.x, wall.y).r - a_wall) > 0.001:
		fail("no metallic map does not fall back to Unity's flat black default")

func _check_isolate(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var wall := probe(false)
	var plate := probe(true)
	# Unity's `sample2Isolate`: the map becomes sample 2's mask alone, written as
	# smoothness, so a fully-marked region reads smoothness 1 (roughness 0) and
	# an unmarked region reads smoothness 0 (roughness 1). High Pass Overlay 0
	# keeps the gain out of the reading.
	var iso: Dictionary = params.duplicate()
	var iso1: Dictionary = params.duplicate()
	iso["isolate_sample2"] = true
	iso["use_sample1"] = false
	iso["blur_overlay"] = 0.0
	iso1["isolate_sample1"] = true
	iso1["use_sample2"] = false
	iso1["blur_overlay"] = 0.0
	var i := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, iso)
	var j := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, iso1)
	var i_wall := i.get_pixel(wall.x, wall.y).r
	var i_plate := i.get_pixel(plate.x, plate.y).r
	var j_plate := j.get_pixel(plate.x, plate.y).r
	var j_wall := j.get_pixel(wall.x, wall.y).r
	print("isolate sample 2: wall %.3f, plate %.3f  |  isolate sample 1: plate %.3f, wall %.3f" % [i_wall, i_plate, j_plate, j_wall])
	# The stone pattern is procedural, so a wall pixel is close to sample 2's
	# brown swatch, not exactly it: its mark is strong, and the isolate map
	# reads it as smoothness, so roughness lands well below base 0.9.
	if i_wall > 0.4:
		fail("isolate sample 2 should paint the wall's mask as smoothness, so the marked wall should read well below base, got %.3f" % i_wall)
	if i_plate < 0.5:
		fail("isolate sample 2 should leave the plate barely marked, the plate is far from the brick brown, got %.3f" % i_plate)
	if j_plate > 0.05:
		fail("isolate sample 1 should paint the plate's mask as smoothness, the plate is sample 1's steel, got %.3f" % j_plate)
	if j_wall < 0.5:
		fail("isolate sample 1 should leave the brown wall barely marked, got %.3f" % j_wall)
	# Isolate overrides every level, so the two samples read the same map only
	# when both masks agree.
	if absf(i_wall - j_wall) < 0.1:
		fail("isolating sample 2 and isolating sample 1 read the same wall value, the two swatches mark the wall differently")

func _check_reveal_is_preview_only(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var at_seam: Dictionary = params.duplicate()
	at_seam["reveal"] = 0.12
	var before := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, params)
	var after := await RoughnessFromDiffuse.new().generate(source, blit, source, flat, at_seam)
	var worst := 0.0
	for y in range(0, SIZE, 4):
		for x in range(0, SIZE, 4):
			worst = maxf(worst, absf(before.get_pixel(x, y).r - after.get_pixel(x, y).r))
	print("reveal slider, GPU map delta between seam 0.5 and 0.12: %.5f" % worst)
	if worst > 0.001:
		fail("the reveal slider changed the map, it is a preview split only")

func _check_panel_rows(source: Image, blit: Blit) -> void:
	var settings := RoughnessFromDiffuse.defaults()
	settings["sample_color1"] = STEEL
	var panel: RoughnessPanel = load(RoughnessMapModule.PANEL_SCENE_PATH).instantiate()
	add_child(panel)
	panel.setup(settings, false)
	# Materialize's `SmoothnessSettings` defaults, read through the widgets.
	# Unity's smoothness numbers invert: MetalSmoothness 0.7 is Metal Roughness
	# 0.3, BaseSmoothness 0.1 is Base Roughness 0.9, SampleSmoothness 0.5 is
	# Sample 1 Roughness 0.5, SampleSmoothness2 0.3 is Sample 2 Roughness 0.7.
	var expected := {
		"metal_roughness": 0.3, "base_roughness": 0.9,
		"sample1_roughness": 0.5, "sample2_roughness": 0.7,
		"hue_weight1": 1.0, "sat_weight1": 0.5, "lum_weight1": 0.2,
		"mask_low1": 0.0, "mask_high1": 1.0,
		"hue_weight2": 1.0, "sat_weight2": 0.5, "lum_weight2": 0.2,
		"mask_low2": 0.0, "mask_high2": 1.0,
		"reveal": 0.5, "blur_size": 0.0, "overlay_blur_size": 30.0,
		"blur_overlay": 3.0, "final_contrast": 1.0, "final_bias": 0.0,
	}
	var got := {
		"metal_roughness": panel.metal_roughness_slider.value,
		"base_roughness": panel.base_roughness_slider.value,
		"sample1_roughness": panel.sample1_faders[5].slider.value,
		"sample2_roughness": panel.sample2_faders[5].slider.value,
		"hue_weight1": panel.sample1_faders[0].slider.value,
		"sat_weight1": panel.sample1_faders[1].slider.value,
		"lum_weight1": panel.sample1_faders[2].slider.value,
		"mask_low1": panel.sample1_faders[3].slider.value,
		"mask_high1": panel.sample1_faders[4].slider.value,
		"hue_weight2": panel.sample2_faders[0].slider.value,
		"sat_weight2": panel.sample2_faders[1].slider.value,
		"lum_weight2": panel.sample2_faders[2].slider.value,
		"mask_low2": panel.sample2_faders[3].slider.value,
		"mask_high2": panel.sample2_faders[4].slider.value,
		"reveal": panel.reveal_slider.value,
		"blur_size": panel.blur_size_slider.value,
		"overlay_blur_size": panel.overlay_blur_slider.value,
		"blur_overlay": panel.high_pass_slider.value,
		"final_contrast": panel.final_contrast_slider.value,
		"final_bias": panel.final_bias_slider.value,
	}
	for key in expected:
		if absf(float(got[key]) - float(expected[key])) > 0.001:
			fail("the panel opens at %s = %s, Materialize opens at %s" % [key, got[key], expected[key]])
	# The fader arrays must be in Unity's drawing order, and each row must write
	# its own key: write one value per row and read the settings back, so an
	# array out of order shows up as a key mismatch. The values stay inside the
	# faders' 0..1 range so the slider does not clamp.
	var order := ["hue_weight1", "sat_weight1", "lum_weight1", "mask_low1",
			"mask_high1", "sample1_roughness"]
	for i in panel.sample1_faders.size():
		var write := 0.1 * float(i + 1)
		panel.sample1_faders[i].slider.value = write
		if absf(float(settings[order[i]]) - write) > 0.001:
			fail("sample 1 fader row %d writes %s = %s, expected %s" % [i, order[i], settings[order[i]], write])
	var order2 := ["hue_weight2", "sat_weight2", "lum_weight2", "mask_low2",
			"mask_high2", "sample2_roughness"]
	for i in panel.sample2_faders.size():
		var write2 := 0.1 * float(i + 1)
		panel.sample2_faders[i].slider.value = write2
		if absf(float(settings[order2[i]]) - write2) > 0.001:
			fail("sample 2 fader row %d writes the wrong key, got %s = %s" % [i, order2[i], settings[order2[i]]])
	panel.refresh()
	# Materialize opens with every sample and level switch off, and with the
	# pristine source on (`SmoothnessGui.cs` lines 5-119).
	if bool(settings["use_sample1"]) or bool(settings["use_sample2"]):
		fail("Materialize opens with both colour samples off")
	if bool(settings["isolate_sample1"]) or bool(settings["isolate_sample2"]):
		fail("Materialize opens with Isolate Mask off")
	if bool(settings["use_adjusted_diffuse"]):
		fail("the panel must open on pristine diffuse, Unity's `useOriginalDiffuse` default")
	if not bool(settings["use_original_diffuse"]):
		fail("the panel must open on pristine diffuse")
	if panel.color1_picker.color != STEEL:
		fail("the sample 1 swatch does not show the picked colour")
	if panel.set_button.text != "Set as Roughness":
		fail("the set button reads %s, Materialize's label is Set as Roughness" % panel.set_button.text)
	# Unity draws a sample's swatch, Pick Color and faders only while its Use
	# box is on, so the fold body is closed and Isolate is greyed out with it.
	if not panel.sample1_fold.collapsed:
		fail("sample 1's body must be folded while Use Color Sample 1 is off")
	if not panel.isolate1_check.disabled:
		fail("Isolate Mask must be greyed out while its sample is off, Unity's `GUI.enabled`")
	panel.use1_check.button_pressed = true
	if panel.sample1_fold.collapsed:
		fail("sample 1's body did not open with Use Color Sample 1")
	if panel.isolate1_check.disabled:
		fail("Isolate Mask stayed greyed out with its sample on")
	# Isolate is a per-sample switch: turning one sample off turns its own
	# isolate off, and isolating one sample turns the other sample's isolate off
	# (`SmoothnessGui.cs` lines 482-485, 524-527).
	panel.isolate1_check.button_pressed = true
	panel.use2_check.button_pressed = true
	if bool(settings["isolate_sample2"]):
		fail("isolate sample 1 did not clear sample 2's isolate")
	panel.isolate2_check.button_pressed = true
	if bool(settings["isolate_sample1"]):
		fail("isolate sample 2 did not clear sample 1's isolate")
	panel.use1_check.button_pressed = false
	if bool(settings["isolate_sample1"]):
		fail("switching sample 1 off did not clear its own isolate")
	# The source row is a radio pair, Unity's `GUI.Toggle`: turning one side on
	# turns the other off, and turning both off forces the pristine source back.
	panel.use_edited_check.button_pressed = true
	if bool(settings["use_original_diffuse"]):
		fail("turning Use Edited Diffuse on did not switch Use Original Diffuse off")
	panel.use_original_check.button_pressed = true
	panel.use_edited_check.button_pressed = false
	panel.use_original_check.button_pressed = false
	if not bool(settings["use_original_diffuse"]):
		fail("turning both source boxes off did not force the pristine source back on")
	# A widget edit writes straight through, and the label follows.
	panel.blur_size_slider.value = 40
	if int(float(settings["blur_size"])) != 40:
		fail("the Sample Blur Size slider did not write through to settings")
	if panel.blur_size_label.text != "40.00":
		fail("the blur size label reads %s, expected 40.00" % panel.blur_size_label.text)
	# The map must follow the settings the panel writes, through the driver:
	# bind a fresh settings Dictionary, drive the widgets the user drives, and
	# run the passes on those settings.
	var live := RoughnessFromDiffuse.defaults()
	panel.setup(live, true)
	panel.color2_picker.color = BRICK
	panel.use2_check.button_pressed = true
	panel.sample2_faders[4].slider.value = 0.2
	if absf(float(live["mask_high2"]) - 0.2) > 0.001:
		fail("sample 2's High fader did not write through to settings")
	var tight: Dictionary = live.duplicate()
	tight["mask_high2"] = 0.2
	var loose: Dictionary = live.duplicate()
	loose["mask_high2"] = 1.0
	var blit_for_panel := Blit.new()
	add_child(blit_for_panel)
	blit_for_panel.setup(load(RoughnessFromDiffuse.SHADER_PATH), source.get_size())
	var flat := Blit.flat(source.get_size(), 0.0)
	var wall := probe(false)
	var a := await RoughnessFromDiffuse.new().generate(source, blit_for_panel, source, flat, tight)
	var b := await RoughnessFromDiffuse.new().generate(source, blit_for_panel, source, flat, loose)
	if a.get_pixel(wall.x, wall.y).r >= b.get_pixel(wall.x, wall.y).r:
		fail("the panel's sample 2 High fader did not reach the map: narrowing High drives the brown wall fully onto sample 2's smoother level, so roughness must fall")
	print("panel rows are bound and drive the map")

