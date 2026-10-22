extends Node
## Live preview test for the Diffuse module. It drives the panel widgets like
## the user does, checks the split-screen preview uniforms (`split_reveal` +
## `original`), checks that a generation slider regenerates from the pristine
## source, checks that "Set as Diffuse" re-runs the chain, and checks that
## Clear restores the source.

const SIZE := Vector2i(256, 256)

var _main: Node
var _panel: Node
var _frames := 0
var _phase := 0
var _source_mean := 0.0

const PHASE_READY := 0
const PHASE_SLIDER := 1
const PHASE_EDITING := 2
const PHASE_EDIT_READY := 3
const PHASE_APPLY := 4
const PHASE_APPLY_READY := 5
const PHASE_CLEAR := 6

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 900:
		print("diffuse live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_READY:
			if not _main._status.text.contains("ready"):
				return
			_ready_phase()
		PHASE_SLIDER:
			_slider_phase()
		PHASE_EDITING:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_EDIT_READY
		PHASE_EDIT_READY:
			if not _main._status.text.contains("ready"):
				return
			_edit_phase()
		PHASE_APPLY:
			(_panel.get_node("Column/ApplyButton") as Button).pressed.emit()
			_phase = PHASE_APPLY_READY
		PHASE_APPLY_READY:
			if not _main._status.text.contains("ready"):
				return
			_apply_phase()
		PHASE_CLEAR:
			_clear_phase()

func _ready_phase() -> void:
	# Activating the module swaps its panel into MapOptionsPanel and makes the
	# mesh show Diffuse, so the split reveal is the preview control.
	_main._activate(_main.modules["diffuse"])
	_main._set_reveal()
	_panel = _main._panel_slot.get_child(0)
	var source: Image = _main.maps["diffuse_original"]
	_source_mean = _mean(source)
	var split: float = _main._mesh_material.get_shader_parameter("split_reveal")
	var original: ImageTexture = _main._mesh_material.get_shader_parameter("original")
	print("status: ", _main._status.text)
	print("panel in slot: ", _panel.name, " slider rows: ", _panel.SLIDER_ROWS.size())
	print("settings: ", _main.modules["diffuse"].settings())
	print("split_reveal on mesh material: ", split, " original texture bound: ", original != null)
	print("box map equals the pristine source before any edit: ", _same(_main.maps["diffuse"], source))
	_phase = PHASE_SLIDER

func _slider_phase() -> void:
	var reveal: Slider = _panel.get_node("Column/RevealGroup/Reveal")
	reveal.value = 0.3
	var split: float = _main._mesh_material.get_shader_parameter("split_reveal")
	var settings: Dictionary = _main.modules["diffuse"].settings()
	print("reveal slider writes settings reveal=", settings["reveal"],
		" split_reveal=", split, " reveal label=", _panel.get_node("Column/RevealGroup/RevealVal").text)
	print("avg blur label=", _panel.get_node("Column/AvgBlurGroup/AvgBlurVal").text,
		" contrast label=", _panel.get_node("Column/ContrastGroup/ContrastVal").text)
	# Drive generation sliders: Contrast 2 and Keep Original Color 0 make the
	# edited map clearly brighter than the source.
	_panel.get_node("Column/ContrastGroup/Contrast").value = 2.0
	_panel.get_node("Column/KeepColorGroup/KeepColor").value = 0.0
	_phase = PHASE_EDITING

func _edit_phase() -> void:
	var source: Image = _main.maps["diffuse_original"]
	var edited: Image = _main.maps["diffuse"]
	print("edited mean %.4f vs source mean %.4f, max pixel delta %.4f"
		 % [_mean(edited), _source_mean, _max_delta(edited, source)])
	print("PASS: dragging Contrast+KeepColor regenerated from the pristine source"
			if _mean(edited) > _source_mean + 0.05 and not _same(edited, source)
			else "FAIL: the edited map did not move from the source")
	print("split_reveal=", _main._mesh_material.get_shader_parameter("split_reveal"),
		" after regeneration")
	_phase = PHASE_APPLY

func _apply_phase() -> void:
	var source: Image = _main.maps["diffuse_original"]
	var edited: Image = _main.maps["diffuse"]
	print("Set as Diffuse: status=", _main._status.text,
		" edited mean %.4f, equals source: " % _mean(edited), _same(edited, source))
	_phase = PHASE_CLEAR

func _clear_phase() -> void:
	# Diffuse Clear restores the pristine source: the box and the mesh show the
	# unedited diffuse, and the split reveal keeps the seam on the source.
	_main._on_box_button("clear", "diffuse")
	var source: Image = _main.maps["diffuse_original"]
	var map: Image = _main.maps["diffuse"]
	var split: float = _main._mesh_material.get_shader_parameter("split_reveal")
	var original: ImageTexture = _main._mesh_material.get_shader_parameter("original")
	var ok := _same(map, source)
	var original_ok := original != null and original.get_size() == Vector2(source.get_size())
	print("after Clear: box map equals source: ", ok,
		" mesh map equals source: ", _main._mesh_map == "diffuse",
		" split_reveal=", split, " original size=", original.get_size())
	print("PASS: Clear restores the source for the split preview" if ok and original_ok
			else "FAIL: Clear did not restore the source")
	get_tree().quit()

func _mean(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			total += (pixel.r + pixel.g + pixel.b) / 3.0
	return total / float(image.get_width() * image.get_height())

func _max_delta(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 1.0
	var worst := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var pa: Color = a.get_pixel(x, y)
			var pb: Color = b.get_pixel(x, y)
			worst = max(worst, abs(pa.r - pb.r))
			worst = max(worst, abs(pa.g - pb.g))
			worst = max(worst, abs(pa.b - pb.b))
	return worst

func _same(a: Image, b: Image) -> bool:
	if a == null or b == null:
		return a == b
	if a.get_size() != b.get_size():
		return false
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				return false
	return true
