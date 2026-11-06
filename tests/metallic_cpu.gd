extends Node
# CPU mirror of MapModules/metallicMap/metallic_from_diffuse.gdshader, the BLUR
# pair and the METALLIC pass. The GPU chain must equal the CPU chain.
#
# fragMetallic scores how CLOSE each blurred pixel is to the picked metal
# colour (1.0 - the distance in hue, sat, lum), puts that score through the
# Low/High smoothstep, then adds the high pass overlay. A pixel that matches
# the swatch scores 1 and becomes metal; a pixel far from it scores 0.
#
# The source is `TestPattern.stone`, the warm brick wall the suite uses, with a
# bright steel plate painted on it: the colour "Pick Color" finds on a metal
# region. With the swatch set to that steel, the plate maps to 1 and the wall
# lands in the middle.

const SIZE := 256
const GREY := Vector3(0.3, 0.5, 0.2)
const METAL := Color(0.80, 0.82, 0.86)
const PLATE := Rect2i(153, 56, 66, 41)
const DELTA := 0.03

var failures := 0

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var source := _make_source()
	var params := MetallicFromDiffuse.defaults()
	# The swatch is the steel plate, the colour a pick on the plate would write.
	params["metal_color"] = METAL
	params["sample_uv"] = Vector2(0.64, 0.30)

	await _check_chain(source, blit, params)
	await _check_mask_edges(source, blit, params)
	await _check_weights(source, blit, params)
	await _check_blur_size(source, blit, params)
	await _check_source_row(source, blit, params)
	await _check_reveal_is_preview_only(source, blit, params)
	await _check_panel_rows(source, blit)

	if failures == 0:
		print("metallic cpu reference: all checks passed")
	else:
		print("METALLIC CPU TEST FAILED, see messages above")
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
			img.set_pixel(x, y, METAL)
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
# window, zero at the ends, wrap addressing. Unity's _BlurSpread is 1.0 for
# Metallic, so one tap is one pixel.
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

# METALLIC pass, the same maths as fragMetallic: closeness to the swatch, the
# Low/High smoothstep, the contrast and bias grade, the high pass overlay.
func metallic_cpu(source: Image, blur_map: Image, overlay_map: Image, params: Dictionary) -> Image:
	var out := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	var metal_hsl := rgb_to_hsl(params["metal_color"])
	var divisor := maxf(float(params["hue_weight"]) + float(params["sat_weight"])
			+ float(params["lum_weight"]), 0.0001)
	for y in SIZE:
		for x in SIZE:
			var blur_hsl := rgb_to_hsl(blur_map.get_pixel(x, y))
			var hue_dif := 1.0 - minf(minf(absf(blur_hsl.x - metal_hsl.x),
					absf((blur_hsl.x + 1.0) - metal_hsl.x)),
					absf((blur_hsl.x - 1.0) - metal_hsl.x)) * 2.0
			var sat_dif := 1.0 - absf(blur_hsl.y - metal_hsl.y)
			var lum_dif := 1.0 - absf(blur_hsl.z - metal_hsl.z)
			var final_diff := (hue_dif * float(params["hue_weight"])
					+ sat_dif * float(params["sat_weight"])
					+ lum_dif * float(params["lum_weight"])) / divisor
			final_diff = smoothstep(float(params["mask_low"]), float(params["mask_high"]), final_diff)
			final_diff = clampf((final_diff - 0.5) * float(params["final_contrast"])
					+ 0.5 + float(params["final_bias"]), 0.0, 1.0)
			var main_c := source.get_pixel(x, y)
			var o := overlay_map.get_pixel(x, y)
			var overlay_grey := Vector3(main_c.r - o.r, main_c.g - o.g, main_c.b - o.b).dot(GREY)
			final_diff *= clampf(overlay_grey * float(params["blur_overlay"]) + 1.0, 0.0, 10.0)
			final_diff = clampf(final_diff, 0.0, 1.0)
			out.set_pixel(x, y, Color(final_diff, final_diff, final_diff))
	return out

# The CPU chain, the passes the driver runs in order. Blur Size 0 copies the
# source, Unity's early `Graphics.Blit` (`MetallicGui.cs` lines 493-495).
func cpu_chain(source: Image, params: Dictionary) -> Image:
	var base: Image = source.duplicate()
	var blur_size := int(round(float(params["blur_size"])))
	if blur_size > 0:
		base = blur_cpu(base, 0, blur_size)
		base = blur_cpu(base, 1, blur_size)
	var overlay_size := int(round(float(params["overlay_blur_size"])))
	var overlay: Image = source.duplicate()
	overlay = blur_cpu(overlay, 0, overlay_size)
	overlay = blur_cpu(overlay, 1, overlay_size)
	return metallic_cpu(source, base, overlay, params)

func chain_delta(source: Image, blit: Blit, params: Dictionary) -> float:
	var gpu := await MetallicFromDiffuse.new().generate(source, blit, params)
	var cpu := cpu_chain(source, params)
	var worst := 0.0
	for y in range(0, SIZE, 4):
		for x in range(0, SIZE, 4):
			worst = maxf(worst, absf(gpu.get_pixel(x, y).r - cpu.get_pixel(x, y).r))
	return worst

func _check_chain(source: Image, blit: Blit, params: Dictionary) -> void:
	blit.setup(load(MetallicFromDiffuse.SHADER_PATH), source.get_size())
	var gpu_overlay := await blit.blit(Blit.to_float(source), MetallicFromDiffuse.new()._blur_params(Vector2(1.0, 0.0), 30.0))
	gpu_overlay = await blit.blit(gpu_overlay, MetallicFromDiffuse.new()._blur_params(Vector2(0.0, 1.0), 30.0))
	var cpu_overlay := blur_cpu(blur_cpu(source, 0, 30), 1, 30)
	for q in [Vector2i(40, 200), Vector2i(8, 8), Vector2i(186, 76)]:
		var g := gpu_overlay.get_pixel(q.x, q.y)
		var c := cpu_overlay.get_pixel(q.x, q.y)
		print("overlay (%d,%d) gpu %.4f %.4f %.4f cpu %.4f %.4f %.4f" % [q.x, q.y, g.r, g.g, g.b, c.r, c.g, c.b])
	var gpu_dbg := await MetallicFromDiffuse.new().generate(source, blit, params)
	var cpu_dbg := cpu_chain(source, params)
	for p in [probe(true), probe(false), Vector2i(8, 8), Vector2i(250, 250), Vector2i(120, 40)]:
		print("probe (%d,%d) gpu %.4f cpu %.4f" % [p.x, p.y, gpu_dbg.get_pixel(p.x, p.y).r, cpu_dbg.get_pixel(p.x, p.y).r])
	var worst := await chain_delta(source, blit, params)
	print("full chain, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU metallic map differs from the CPU chain by %.5f" % worst)

func _check_mask_edges(source: Image, blit: Blit, params: Dictionary) -> void:
	var plate := probe(true)
	var wall := probe(false)
	var tight: Dictionary = params.duplicate()
	tight["mask_high"] = 0.2
	var floored: Dictionary = params.duplicate()
	floored["mask_low"] = 0.5
	var a := await MetallicFromDiffuse.new().generate(source, blit, params)
	var b := await MetallicFromDiffuse.new().generate(source, blit, tight)
	var c := await MetallicFromDiffuse.new().generate(source, blit, floored)
	var wall_default := a.get_pixel(wall.x, wall.y).r
	var wall_tight := b.get_pixel(wall.x, wall.y).r
	var wall_floored := c.get_pixel(wall.x, wall.y).r
	print("wall response: %.3f default, %.3f with High 0.2, %.3f with Low 0.5" % [wall_default, wall_tight, wall_floored])
	if wall_default < 0.15 or wall_default > 0.6:
		fail("the wall landed at %.3f, Materialize scores a distant region in the middle" % wall_default)
	if wall_tight <= wall_default:
		fail("narrowing the smoothstep to High 0.2 did not push the wall to full metal")
	if wall_floored >= wall_default:
		fail("raising the smoothstep floor to Low 0.5 did not cut the wall response")
	# The plate IS the picked colour, so its score is 1 at any mask edge.
	for p in [a, b, c]:
		if p.get_pixel(plate.x, plate.y).r < 0.95:
			fail("the plate, the picked colour, did not map to full metal")

func _check_weights(source: Image, blit: Blit, params: Dictionary) -> void:
	var wall := probe(false)
	var hue_heavy: Dictionary = params.duplicate()
	hue_heavy["hue_weight"] = 1.0
	hue_heavy["sat_weight"] = 0.0
	hue_heavy["lum_weight"] = 0.0
	var lum_heavy: Dictionary = params.duplicate()
	lum_heavy["hue_weight"] = 0.0
	lum_heavy["sat_weight"] = 0.0
	lum_heavy["lum_weight"] = 1.0
	var a := await MetallicFromDiffuse.new().generate(source, blit, hue_heavy)
	var b := await MetallicFromDiffuse.new().generate(source, blit, lum_heavy)
	var a_wall := a.get_pixel(wall.x, wall.y).r
	var b_wall := b.get_pixel(wall.x, wall.y).r
	print("wall with the Hue fader alone: %.3f, with the Lum fader alone: %.3f" % [a_wall, b_wall])
	if b_wall <= a_wall:
		fail("the wall is far in hue and closer in luminance, the Lum fader alone should score it higher")
	if absf(a_wall - b_wall) < 0.1:
		fail("the Hue / Sat / Lum faders did not change the colour score")
	# All three faders at 0 is a legal slider state, the divisor is clamped.
	var zeroed: Dictionary = params.duplicate()
	zeroed["hue_weight"] = 0.0
	zeroed["sat_weight"] = 0.0
	zeroed["lum_weight"] = 0.0
	var z := await MetallicFromDiffuse.new().generate(source, blit, zeroed)
	if z.get_pixel(wall.x, wall.y).r < 0.0:
		fail("all faders at 0 produced a negative map value")

func _check_blur_size(source: Image, blit: Blit, params: Dictionary) -> void:
	var sharp: Dictionary = params.duplicate()
	sharp["blur_size"] = 0.0
	var blurred: Dictionary = params.duplicate()
	blurred["blur_size"] = 30.0
	var worst := await chain_delta(source, blit, sharp)
	print("Blur Size 0, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU differs from the CPU chain at Blur Size 0 by %.5f" % worst)
	worst = await chain_delta(source, blit, blurred)
	print("Blur Size 30, worst channel delta: %.5f" % worst)
	if worst > DELTA:
		fail("the GPU differs from the CPU chain at Blur Size 30 by %.5f" % worst)
	# Softening the colour bleeds the plate's steel onto the wall, so a pixel
	# just off the plate scores closer to the swatch and gets more metal.
	var a := await MetallicFromDiffuse.new().generate(source, blit, sharp)
	var b := await MetallicFromDiffuse.new().generate(source, blit, blurred)
	var edge := Vector2i(PLATE.position.x - 6, PLATE.position.y + 20)
	var a_edge := a.get_pixel(edge.x, edge.y).r
	var b_edge := b.get_pixel(edge.x, edge.y).r
	print("just off the plate: %.3f at Blur Size 0, %.3f at Blur Size 30" % [a_edge, b_edge])
	if b_edge <= a_edge:
		fail("blurring did not spread the plate's metal score onto the wall")

func _check_source_row(source: Image, blit: Blit, params: Dictionary) -> void:
	# The row is a radio pair: " Use Original Diffuse" reads the pristine
	# source, " Use Edited Diffuse" reads the edited diffuse the shell hands in.
	var edited: Image = source.duplicate()
	for y in SIZE:
		for x in SIZE:
			var c := edited.get_pixel(x, y)
			edited.set_pixel(x, y, Color(c.r * 1.25, c.g * 1.25, c.b * 1.25))
	var on_original: Dictionary = params.duplicate()
	on_original["use_original_diffuse"] = true
	on_original["use_adjusted_diffuse"] = false
	var on_edited: Dictionary = params.duplicate()
	on_edited["use_original_diffuse"] = false
	on_edited["use_adjusted_diffuse"] = true
	var wall := probe(false)
	var a := await MetallicFromDiffuse.new().generate(edited, blit, on_original, source)
	var b := await MetallicFromDiffuse.new().generate(edited, blit, on_edited, source)
	var a_wall := a.get_pixel(wall.x, wall.y).r
	var b_wall := b.get_pixel(wall.x, wall.y).r
	print("wall on the pristine source: %.3f, wall on the edited diffuse: %.3f" % [a_wall, b_wall])
	if absf(a_wall - b_wall) < 0.02:
		fail("the source row did not change which diffuse the passes read")
	# The pristine run must match running the tool on the pristine map itself.
	var plain := await MetallicFromDiffuse.new().generate(source, blit, on_original)
	if absf(plain.get_pixel(wall.x, wall.y).r - a_wall) > 0.001:
		fail("the source row does not read the pristine diffuse when asked for it")

func _check_reveal_is_preview_only(source: Image, blit: Blit, params: Dictionary) -> void:
	var at_seam: Dictionary = params.duplicate()
	at_seam["reveal"] = 0.12
	var worst := await chain_delta(source, blit, at_seam)
	print("reveal slider, worst channel delta: %.5f" % worst)
	if worst > 0.001:
		fail("the reveal slider changed the map, it is a preview split only")

func _check_panel_rows(source: Image, blit: Blit) -> void:
	var settings := MetallicFromDiffuse.defaults()
	settings["metal_color"] = METAL
	var panel: MetallicPanel = load(MetallicMapModule.PANEL_SCENE_PATH).instantiate()
	add_child(panel)
	panel.setup(settings)
	# Materialize's `MetallicSettings` defaults, read through the widgets.
	var expected := {
		"hue_weight": 1.0, "sat_weight": 0.5, "lum_weight": 0.2,
		"mask_low": 0.0, "mask_high": 1.0, "reveal": 0.5,
		"blur_size": 0.0, "overlay_blur_size": 30.0,
		"blur_overlay": 1.0, "final_contrast": 1.0, "final_bias": 0.0,
	}
	var got := {
		"hue_weight": panel.weight_faders[0].slider.value,
		"sat_weight": panel.weight_faders[1].slider.value,
		"lum_weight": panel.weight_faders[2].slider.value,
		"mask_low": panel.weight_faders[3].slider.value,
		"mask_high": panel.weight_faders[4].slider.value,
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
	var names: Array[String] = []
	for row in panel.weight_faders:
		names.append(row.name)
	print("fader rows: " + ", ".join(names))
	if names != ["Hue", "Sat", "Lum", "Low", "High"]:
		fail("the fader array is not in Hue / Sat / Lum / Low / High order")
	if not panel.use_original_check.button_pressed:
		fail("the panel must open on pristine diffuse")
	if panel.use_edited_check.button_pressed:
		fail("the panel must not open on edited diffuse")
	if panel.metal_color_picker.color != METAL:
		fail("the picked colour swatch does not show the sample")
	if panel.set_button.text != "Set as Metallic":
		fail("the set button reads %s, Materialize's label is Set as Metallic" % panel.set_button.text)
	# A widget edit writes straight through to the settings Dictionary.
	panel.blur_size_slider.value = 40
	if int(float(settings["blur_size"])) != 40:
		fail("the blur size slider did not write through to settings")
	if panel.blur_size_label.text != "40.00":
		fail("the blur size label reads %s, expected 40.00" % panel.blur_size_label.text)
	panel.weight_faders[4].slider.value = 0.2
	if absf(float(settings["mask_high"]) - 0.2) > 0.001:
		fail("the High fader did not write through to settings")
	# The map must follow the settings the panel writes, through the driver.
	var wall := probe(false)
	var tight: Dictionary = settings.duplicate()
	tight["mask_high"] = 0.2
	tight["blur_size"] = 0.0
	var loose: Dictionary = settings.duplicate()
	loose["mask_high"] = 1.0
	loose["blur_size"] = 0.0
	var a := await MetallicFromDiffuse.new().generate(source, blit, tight, source)
	var b := await MetallicFromDiffuse.new().generate(source, blit, loose, source)
	if a.get_pixel(wall.x, wall.y).r <= b.get_pixel(wall.x, wall.y).r:
		fail("the panel's High fader did not reach the map")
	print("panel rows are bound and drive the map")
