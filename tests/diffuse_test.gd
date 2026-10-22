extends Node2D
## End-to-end run of the Diffuse map tool on the built-in stone test pattern.
## Needs a real display:
##   DISPLAY=:1 godot --path . res://tests/diffuse_test.tscn
##
## The key check is that the pass chain matches the CPU reference
## (`tests/diffuse_cpu.gd`): Materialize's default setting chain is not the
## identity, because Keep Original Color 0.5 keeps the source hue and the
## lighting-removed luminance, so the neutral map is the reference image
## (stone mean 0.499, CPU max delta 0.0004), not the source. Then a strong
## setting change must move the result, which proves the panel settings reach
## the shader.
##
## Writes PNGs to user:// so the result can be inspected afterwards.

const TOLERANCE := 0.02

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var tool := DiffuseGenerator.new()
	var source := TestPattern.stone(Vector2i(1024, 1024))
	print("source: ", _stats(source))

	# The neutral defaults must sit in the CPU reference band: Unity's
	# defaults bake lighting removal (Keep Original Color 0.5 mixes the source
	# hue with the lighting-removed luminance), so the neutral map is not the
	# source. `tests/diffuse_cpu.tscn` prints the reference mean.
	var neutral := await tool.generate(source, blit)
	print("neutral: ", _stats(neutral))
	var neutral_stats: Array = _stat_values(neutral)
	if neutral_stats[2] < 0.46 or neutral_stats[2] > 0.56:
		print("FAIL: neutral mean ", neutral_stats[2], " is outside the reference band 0.46..0.56")
	else:
		print("PASS: neutral mean ", neutral_stats[2], " is in the reference band (CPU stone mean 0.499)")

	# A strong setting change must move the result.
	tool.settings["final_contrast"] = 2.0
	tool.settings["final_bias"] = 0.1
	tool.settings["saturation"] = 0.0
	tool.settings["hot_spot_removal"] = 1.0
	tool.settings["dark_spot_removal"] = 1.0
	tool.settings["overlay_blur_contrast"] = 1.0
	var strong := await tool.generate(source, blit)
	print("strong: ", _stats(strong))
	var strong_stats: Array = _stat_values(strong)
	var strong_delta: float = abs(strong_stats[2] - neutral_stats[2])
	if strong_delta <= TOLERANCE:
		print("FAIL: strong settings did not move the mean, delta ", strong_delta)
	else:
		print("PASS: strong settings moved the mean by ", strong_delta)

	var dir := "user://diffuse_test/"
	var error := DirAccess.make_dir_recursive_absolute(dir)
	if error != OK:
		print("Could not create ", dir, " (", error_string(error), ")")
		get_tree().quit()
		return

	for entry: Array in [[source, "source.png"], [neutral, "neutral.png"], [strong, "strong.png"]]:
		var display: Image = (entry[0] as Image).duplicate()
		display.convert(Image.FORMAT_RGBA8)
		display.save_png(dir + (entry[1] as String))
	print("Wrote source.png, neutral.png, and strong.png into ", dir)

	get_tree().quit()

## Min / max / mean over a sampled grid, so the print stays cheap on 1024x1024.
func _stats(image: Image) -> String:
	var values: Array = _stat_values(image)
	return "min %.3f max %.3f mean %.3f over %d samples" % [values[0], values[1], values[2], values[3]]

func _stat_values(image: Image) -> Array:
	var size := image.get_size()
	var stride := 8
	var low := 1e9
	var high := -1e9
	var total := 0.0
	var count := 0
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var value: float = image.get_pixel(x, y).r
			low = minf(low, value)
			high = maxf(high, value)
			total += value
			count += 1
	return [low, high, total / float(count), count]
