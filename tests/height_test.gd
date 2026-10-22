extends Node2D
## End-to-end run of Height From Diffuse on the built-in stone test pattern.
## Needs a real display:
##   DISPLAY=:1 godot --path . res://tests/height_test.tscn
##
## Writes PNGs to user:// so the result can be inspected afterwards, and prints
## statistics for the source, the pyramid, the average map, and the result.

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var tool := HeightFromDiffuse.new()
	var source := TestPattern.stone(Vector2i(1024, 1024))
	print("source: ", _stats(source))

	var result := await tool.generate(source, blit)
	print("result format=", result.get_format(), " size=", result.get_size())
	print("result: ", _stats(result))

	var dir := "user://height_test/"
	var error := DirAccess.make_dir_recursive_absolute(dir)
	if error != OK:
		print("Could not create ", dir, " (", error_string(error), ")")
		get_tree().quit()
		return

	var result_png := dir + "result.png"
	var display := result.duplicate()
	display.convert(Image.FORMAT_RGBA8)
	display.save_png(result_png)
	var source_png := dir + "source.png"
	var source_display := source.duplicate()
	source_display.convert(Image.FORMAT_RGBA8)
	source_display.save_png(source_png)
	print("Wrote ", result_png, " and ", source_png)

	get_tree().quit()

## Min / max / mean over a sampled grid, so the print stays cheap on 1024x1024.
func _stats(image: Image) -> String:
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
	return "min %.3f max %.3f mean %.3f over %d samples" % [low, high, total / float(count), count]
