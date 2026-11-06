extends Node2D
## Probe for the blit framework, with a real display:
##   DISPLAY=:1 godot --path . res://tests/blit_probe.tscn
##
## Checks, in order:
##  1. a canvas_item shader runs in an offscreen SubViewport and the result can
##     be read back as an Image (format and values),
##  2. a flat value pass writes what the shader writes,
##  3. HDR 2D keeps values above 1.0 through the render target,
##  4. repeat wrapping works for sampling outside 0..1,
##  5. the raised-cosine blur loop behaves (the red marker spreads horizontally).

func _ready() -> void:
	var blit := Blit.new()
	add_child(blit)

	var source := Image.create_empty(64, 64, false, Image.FORMAT_RGBAF)
	source.fill(Color(0.25, 0.5, 0.75, 1.0))
	source.set_pixel(10, 10, Color(1.0, 0.0, 0.0, 1.0))

	var probe: Shader = load("res://tests/probe.gdshader")
	blit.setup(probe, source.get_size())

	var passthrough: Image = await blit.blit(source)
	print("pass 0 format=", passthrough.get_format(),
			" size=", passthrough.get_size(),
			" pixel(32,32)=", passthrough.get_pixel(32, 32),
			" pixel(10,10)=", passthrough.get_pixel(10, 10))
	print("expect pixel(32,32) = (0.25, 0.5, 0.75), pixel(10,10) = (1, 0, 0)")

	var flat: Image = await blit.blit(source, {"pass": 1, "value": 0.75})
	print("pass 1 pixel(32,32)=", flat.get_pixel(32, 32), " expect (0.75, 0.75, 0.75)")

	var hdr: Image = await blit.blit(source, {"pass": 2, "value": 1.25})
	print("pass 2 HDR pixel(0,0)=", hdr.get_pixel(0, 0),
			" format=", hdr.get_format(), " expect (1.25, 0.625, 0)")

	var wrapped: Image = await blit.blit(source, {"pass": 3, "value": 1.0})
	print("pass 3 repeat wrap pixel(0,0)=", wrapped.get_pixel(0, 0),
			" expect the right edge colour (0.25, 0.5, 0.75)")

	var blurred: Image = await blit.blit(source, {"pass": 4, "value": 1.0})
	print("pass 4 blur pixel(10,10)=", blurred.get_pixel(10, 10))
	print("pass 4 blur pixel(13,10)=", blurred.get_pixel(13, 10),
			"(red marker should spread horizontally, centre tap dominant)")

	get_tree().quit()
