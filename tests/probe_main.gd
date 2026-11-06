extends Node
const SIZE := 256
func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)
	var img := TestPattern.stone(Vector2i(SIZE, SIZE))
	blit.setup(load("res://tests/probe_main.gdshader"), img.get_size())
	var out := await blit.blit(Blit.to_float(img), {"pass": 5, "probe_x": 40.0, "probe_y": 200.0})
	var p := out.get_pixel(40, 200)
	print("probe pass gpu r=%.4f g=%.4f b=%.4f a=%.4f" % [p.r, p.g, p.b, p.a])
	var c := img.get_pixel(40, 200)
	print("source     cpu r=%.4f g=%.4f b=%.4f a=%.4f" % [c.r, c.g, c.b, c.a])
	get_tree().quit()
