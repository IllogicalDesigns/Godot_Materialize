extends Node
const SIZE := 16

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	blit.setup(load("res://tests/probe_hsl.gdshader"), img.get_size())
	var raw := Color(0.80, 0.82, 0.86, 1.0)
	var a := await blit.blit(Blit.to_float(img), {"mode": 9, "as_color": raw})
	var b := await blit.blit(Blit.to_float(img), {"mode": 10, "as_vector": Vector4(raw.r, raw.g, raw.b, 1.0)})
	print("Color uniform   the shader sees %.4f %.4f %.4f" % [a.get_pixel(8, 8).r, a.get_pixel(8, 8).g, a.get_pixel(8, 8).b])
	print("Vector4 uniform the shader sees %.4f %.4f %.4f" % [b.get_pixel(8, 8).r, b.get_pixel(8, 8).g, b.get_pixel(8, 8).b])
	print("the Color object says          %.4f %.4f %.4f" % [raw.r, raw.g, raw.b])
	get_tree().quit()
