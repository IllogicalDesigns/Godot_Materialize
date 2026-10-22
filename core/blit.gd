class_name Blit
extends Node
## GPU "blit" framework - Godot's stand-in for Unity's `Graphics.Blit`.
##
## Materialize is built from full-screen shader passes: read a texture, run a
## fragment program over every pixel, write the result into a render texture,
## and feed that texture to the next pass. Here a pass is a `canvas_item`
## shader drawn on a full-screen quad inside an offscreen `SubViewport`, and
## the result is read back as a Godot `Image`.
##
## The render target is HDR (`use_hdr_2d`), so a pass can carry values outside
## 0..1, and everything is processed as `FORMAT_RGBAF` (32-bit float per
## channel) on the CPU between passes. Float formats skip the sRGB conversion
## that Godot applies to 8-bit textures on upload, so the numbers a generator
## sees are exactly the numbers it wrote in the previous pass.
##
## All samplers use `repeat_enable`, matching the Unity render textures
## (`wrapMode = Repeat`). That is what keeps generated maps tileable.

## Uniform name every generator shader uses for its input image.
const SOURCE_PARAM := "source"
## Uniform name for the size of one source pixel (1 / width, 1 / height).
const TEXEL_PARAM := "texel"

var viewport: SubViewport
var quad: MeshInstance2D
var material: ShaderMaterial

var _target_size := Vector2i(0, 0)

## shader: canvas_item shader holding all passes of one tool.
## size: working resolution, taken from the source image.
func setup(shader: Shader, size: Vector2i) -> void:
	if material == null:
		material = ShaderMaterial.new()
		quad = MeshInstance2D.new()
		quad.material = material

		viewport = SubViewport.new()
		viewport.use_hdr_2d = true
		viewport.transparent_bg = true
		viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.add_child(quad)
		add_child(viewport)

	material.shader = shader
	_target_size = size
	viewport.size = size
	_set_quad_size(size)

## Runs one pass over `src` and returns the result. `params` maps shader
## uniform names to values (float, int, Vector2, Vector3, Color, Image,
## ImageTexture). `Image` values are uploaded for the shader automatically.
func blit(src: Image, params: Dictionary = {}) -> Image:
	var size := src.get_size()
	if size != _target_size:
		_target_size = size
		viewport.size = size
		_set_quad_size(size)

	material.set_shader_parameter(SOURCE_PARAM, ImageTexture.create_from_image(src))
	material.set_shader_parameter(TEXEL_PARAM, Vector2(1.0 / float(size.x), 1.0 / float(size.y)))
	for key: StringName in params:
		var value: Variant = params[key]
		if value is Image:
			value = ImageTexture.create_from_image(value)
		material.set_shader_parameter(key, value)

	await _render_frame()
	return _read_back()

## Chain of passes where each pass feeds the output of the previous one.
## `param_list` is an array of parameter dictionaries, one per pass.
func blit_chain(src: Image, param_list: Array) -> Image:
	var current := src
	for params: Dictionary in param_list:
		current = await blit(current, params)
	return current

## Flat image filled with one value. Materialize uses these as seed maps
## (flat grey height, flat normal, empty masks).
static func flat(size: Vector2i, value: float) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
	image.fill(Color(value, value, value, 1.0))
	return image

## Copy of `image` in the float working format, so passes keep exact values.
## Image.convert() works in place, so the copy is converted, not the input.
static func to_float(image: Image) -> Image:
	var copy := image.duplicate()
	copy.convert(Image.FORMAT_RGBAF)
	return copy

## Copy of `image` in 8-bit for on-screen display or PNG export. The source
## image is left untouched (Image.convert() converts in place).
static func to_display(image: Image) -> Image:
	var copy := image.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	return copy

func _set_quad_size(size: Vector2i) -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size)
	# QuadMesh geometry spans center_offset +/- size / 2, so pushing the
	# centre to half the viewport size covers exactly (0, 0) to (size, size).
	# center_offset is Vector3; only x and y matter in the 2D canvas.
	mesh.center_offset = Vector3(size.x * 0.5, size.y * 0.5, 0.0)
	quad.mesh = mesh
	quad.position = Vector2(0, 0)

## Offscreen viewports draw in the canvas pass of each frame, so a pass is
## finished after the frame post-draw. Yielding keeps passes strictly ordered.
func _render_frame() -> void:
	var tree := get_tree()
	if tree == null:
		push_error("Blit must be inside the scene tree to render passes.")
		return
	await tree.process_frame
	await RenderingServer.frame_post_draw

func _read_back() -> Image:
	var image: Image = viewport.get_texture().get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image
