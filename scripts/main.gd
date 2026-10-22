extends Control
## Shell for the Godot port of Materialize (Unity sample project, Unity
## Technologies 2013, GPLv3). Materialize builds PBR texture maps from a source
## image using GPU "blit" passes. See README.md for the Unity -> Godot mapping
## and docs/how_materialize_works.md for the algorithm.
##
## The window is: source preview (clickable for colour picking), result preview,
## the tool panel, load / test pattern / resolution / generate / save.
## Height From Diffuse is the first tool wired in.

const UNITY_SOURCE := "/home/tiny/AI/materialize/Materialize"

## One row per Unity tool panel, in the order we plan to port it.
## `status` is updated as each tool is ported.
const GENERATORS: Array[Dictionary] = [
	{
		"tool": "Blit framework",
		"unity": "Graphics.Blit + RenderTexture + Hidden/Blit_Shader",
		"target": "core/blit.gd + canvas_item shader passes",
		"status": "done",
	},
	{
		"tool": "Height From Diffuse",
		"unity": "Scripts/HeightFromDiffuseGui.cs + Shaders/Resources/Blit_Sample.shader + Blit_Shader.shader",
		"target": "core/height_from_diffuse.gd + shaders/height_from_diffuse.gdshader",
		"status": "ported (first tool)",
	},
	{
		"tool": "Normal From Height",
		"unity": "Scripts/NormalFromHeightGui.cs + Shaders/Resources/Blit_Normal_From_Height.shader",
		"target": "core/normal_from_height.gd + shaders/normal_from_height.gdshader",
		"status": "not started",
	},
	{
		"tool": "Edge From Normal",
		"unity": "Scripts/EdgeFromNormalGui.cs + Shaders/Resources/Blit_Edge_From_Normal.shader",
		"target": "core/edge_from_normal.gd + shaders/edge_from_normal.gdshader",
		"status": "not started",
	},
	{
		"tool": "AO From Normal",
		"unity": "Scripts/AOFromNormalGui.cs + Shaders/AO_From_Normal_Preview.shader",
		"target": "core/ao_from_normal.gd + shaders/ao_from_normal.gdshader",
		"status": "not started",
	},
	{
		"tool": "Metallic",
		"unity": "Scripts/MetallicGui.cs + Shaders/Resources/Blit_Metallic.shader",
		"target": "core/metallic.gd + shaders/metallic.gdshader",
		"status": "not started",
	},
	{
		"tool": "Smoothness",
		"unity": "Scripts/SmoothnessGui.cs + Shaders/Resources/Blit_Smoothness.shader",
		"target": "core/smoothness.gd + shaders/smoothness.gdshader",
		"status": "not started",
	},
	{
		"tool": "Edit Diffuse",
		"unity": "Scripts/EditDiffuseGui.cs + Shaders/Edit_Diffuse_Preview.shader",
		"target": "core/edit_diffuse.gd + shaders/edit_diffuse.gdshader",
		"status": "not started",
	},
	{
		"tool": "Alignment",
		"unity": "Scripts/AlignmentGui.cs + Shaders/Resources/Blit_Alignment.shader",
		"target": "core/alignment.gd + shaders/alignment.gdshader",
		"status": "not started",
	},
	{
		"tool": "Seamless Tiling",
		"unity": "Scripts/TilingTextureMakerGui.cs + Shaders/Resources/Blit_Seamless_Texture_Maker.shader",
		"target": "core/seamless_tiling.gd + shaders/seamless_tiling.gdshader",
		"status": "not started",
	},
	{
		"tool": "Post Process",
		"unity": "PostProcess/PostProcess.cs + PostProcess/Resources/HiddenPostProcess.shader",
		"target": "core/post_process.gd + shaders/post_process.gdshader",
		"status": "not started",
	},
	{
		"tool": "Material Preview (DNMST)",
		"unity": "Scripts/MaterialGui.cs + Shaders/DNMST.shader",
		"target": "core/material_preview.gd + shaders/dnmst.gdshader",
		"status": "not started",
	},
	{
		"tool": "Save / Load Project",
		"unity": "Scripts/SaveLoadProject.cs",
		"target": "core/project_io.gd",
		"status": "not started",
	},
]

@onready var _panel: VBoxContainer = $Split/Scroll/Panel
@onready var _source_rect: TextureRect = $Split/Left/SourceRect
@onready var _result_rect: TextureRect = $Split/Left/ResultRect
@onready var _status: Label = $Split/Left/Toolbar/Status
@onready var _resolution: OptionButton = $Split/Left/Toolbar/Resolution
@onready var _load_dialog: FileDialog = $LoadDialog
@onready var _save_dialog: FileDialog = $SaveDialog
@onready var _timer: Timer = $Timer

var blit: Blit
var tool: HeightFromDiffuse

## The source image in its original 8-bit form, so resolution changes can
## re-derive the working copy without compounding resizes.
var _source_original: Image
var source_image: Image
var result_image: Image

var _busy := false
var _dirty := false
## Which sample colour slot is waiting for a click on the source preview (0 = none).
var _pick_sample := 0
var _working_size := 1024

func _ready() -> void:
	# Report the roadmap to stdout so headless runs stay useful.
	for row in GENERATORS:
		print("[materialize] %s -> %s [%s]" % [row["tool"], row["target"], row["status"]])

	blit = Blit.new()
	add_child(blit)

	tool = HeightFromDiffuse.new()
	_panel.setup(tool.settings)

	_resolution.add_item("512", 512)
	_resolution.add_item("1024", 1024)
	_resolution.add_item("2048", 2048)
	_resolution.add_item("Source size", 0)
	_resolution.selected = 1

	_status.text = "Load a diffuse image, or use the stone test pattern."

func _on_load_pressed() -> void:
	_load_dialog.show()

func _on_load_file_selected(path: String) -> void:
	var image: Image = Image.load_from_file(path)
	if image == null:
		_status.text = "Could not load %s" % path
		return
	_set_source(image)

func _on_pattern_pressed() -> void:
	var size := _working_size if _working_size > 0 else 1024
	_set_source(TestPattern.stone(Vector2i(size, size)))

func _on_resolution_selected(index: int) -> void:
	_working_size = _resolution.get_item_id(index)
	if _source_original != null:
		_set_source(_source_original)

func _on_generate_pressed() -> void:
	_dirty = false
	_generate()

func _on_settings_changed() -> void:
	_dirty = true
	_timer.start()

func _on_timer_timeout() -> void:
	if _busy:
		return
	if _dirty:
		_dirty = false
		_generate()

func _on_pick_requested(sample_index: int) -> void:
	_pick_sample = sample_index
	_status.text = "Click a colour in the source preview for sample %d." % sample_index

func _on_source_gui_input(event: InputEvent) -> void:
	if _pick_sample == 0 or source_image == null:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var sample_index := _pick_sample
	var size := source_image.get_size()
	var uv: Vector2 = event.position / _source_rect.size
	var x := clampi(int(uv.x * float(size.x)), 0, size.x - 1)
	var y := clampi(int(uv.y * float(size.y)), 0, size.y - 1)
	var picked: Color = source_image.get_pixel(x, y)
	_pick_sample = 0
	_panel.set_sample_color(sample_index, picked)
	_generate()

func _on_save_pressed() -> void:
	if result_image == null:
		_status.text = "Nothing to save yet."
		return
	_save_dialog.show()

func _on_save_file_selected(path: String) -> void:
	var display := Blit.to_display(result_image)
	var error := display.save_png(path)
	if error == OK:
		_status.text = "Saved %s" % path
	else:
		_status.text = "Save failed: %s (%s)" % [path, error_string(error)]

## original: the image as loaded (8-bit), or a procedurally generated float image.
func _set_source(original: Image) -> void:
	_source_original = original
	var working := original.duplicate()
	if _working_size > 0:
		working.resize(_working_size, _working_size, Image.INTERPOLATE_CUBIC)
	source_image = Blit.to_float(working)
	_source_rect.texture = ImageTexture.create_from_image(Blit.to_display(working))
	_generate()

func _generate() -> void:
	if source_image == null:
		_status.text = "No source image loaded."
		return
	if _busy:
		return

	_busy = true
	var size := source_image.get_size()
	_status.text = "Generating %d x %d..." % [size.x, size.y]

	result_image = await tool.generate(source_image, blit)

	_result_rect.texture = ImageTexture.create_from_image(Blit.to_display(result_image))
	_busy = false
	_status.text = "Height map ready: %d x %d" % [size.x, size.y]

	if _dirty:
		_dirty = false
		_generate()
