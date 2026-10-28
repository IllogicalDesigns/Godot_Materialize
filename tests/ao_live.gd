extends Node

## Live test for the AO map pass chain through the running shell.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/ao_live.tscn`) so the SubViewport
## renders and the GPU pass chain runs. It drives the UI the way a user does:
## stone pattern at 512, Height box Create, Normal box Create, AO box Create,
## sliders re-running the chain through the debounce, the Set button, "Show
## full Material", and Clear. The AO chain is ~100 passes, so the frame budget
## is generous, and every phase follows the shell's status label, the same way
## `tests/roughness_live.gd` does: "Generating" -> "ready".
##
## AO reads the Normal map as its source (`AOFromNormalGui.cs` line 323 blits
## `_NormalMap` straight), so Height, then Normal, then AO. The stone wall is
## the input: the groove occludes more than the flat plate, so the mean AO
## falls when the spread widens, a groove column is darker than a plate
## column, and restoring the settings returns the base map, because the ray
## hash is deterministic.
##
## The panel under `MapOptionsPanel/PanelSlot` is replaced every time the
## active module changes, so the test re-fetches it from the slot and never
## keeps a reference across an activation. Every widget is reached through the
## panel's `@export` references, never a node path (`CODING_RULES.md`).

const PHASE_START := 0
const PHASE_SIZE := 1
const PHASE_GEN_HEIGHT := 2
const PHASE_HEIGHT_READY := 3
const PHASE_GEN_NORMAL := 4
const PHASE_NORMAL_READY := 5
const PHASE_GEN_AO := 6
const PHASE_AO_READY := 7
const PHASE_SPREAD := 8
const PHASE_SPREAD_READY := 9
const PHASE_SPREAD_RESTORE := 10
const PHASE_SPREAD_RESTORE_READY := 11
const PHASE_BLEND := 12
const PHASE_BLEND_READY := 13
const PHASE_BLEND_RESTORE := 14
const PHASE_BLEND_RESTORE_READY := 15
const PHASE_CONTRAST := 16
const PHASE_CONTRAST_READY := 17
const PHASE_BIAS := 18
const PHASE_BIAS_READY := 19
const PHASE_BIAS_RESTORE := 20
const PHASE_BIAS_RESTORE_READY := 21
const PHASE_SET := 22
const PHASE_SET_READY := 23
const PHASE_FULL := 24
const PHASE_CLEAR := 25
const PHASE_REGEN := 26
const PHASE_REGEN_READY := 27

const SIZE := 512
## The stone pattern's groove column and the flat plate column. The groove
## walls and floor occlude more than open plate sky, so the groove column is
## the darker one on the AO map.
const GROOVE_X := 256
const PLATE_X := 288

var _frames := 0
var _phase := PHASE_START
var _main: Node
var _panel: Control
var _base_mean := 0.0
var _dark_mean := 0.0
var _failures: Array[String] = []

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 5000:
		print("ao live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the smallest resolution, so
			# the ~100-pass AO chain stays cheap and the test stays readable.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SIZE
			print("ao live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SIZE:
			if not _main._status.text.contains("ready"):
				return
			# AO's source is the Normal map, not the height, so Create is
			# greyed out until a normal map exists.
			var ao_box: MapBox = _main.boxes[5]
			_check(ao_box.create_button.disabled,
					"the AO box Create is disabled with no normal map, the source gate")
			# The Height chain, then the Normal chain: AO needs both, the
			# normal as its source and the height as its depth term.
			_main.boxes[0].create_button.pressed.emit()
			_phase = PHASE_GEN_HEIGHT
			print("ao live: Height box Create")
		PHASE_GEN_HEIGHT:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_HEIGHT_READY
		PHASE_HEIGHT_READY:
			if not _main._status.text.contains("ready"):
				return
			var height: Image = _main.maps["height"]
			_check(height != null and height.get_size() == Vector2i(SIZE, SIZE),
					"the height map is %d x %d, got %s" % [SIZE, SIZE, height.get_size() if height != null else Vector2i()])
			_check(not AOMapModule.new().create_available({"height": height}),
					"the AO box Create is disabled with a height-only store, the source gate")
			_main.boxes[2].create_button.pressed.emit()
			_phase = PHASE_GEN_NORMAL
			print("ao live: Normal box Create")
		PHASE_GEN_NORMAL:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_NORMAL_READY
		PHASE_NORMAL_READY:
			if not _main._status.text.contains("ready"):
				return
			var normal: Image = _main.maps["normal"]
			_check(normal != null and normal.get_size() == Vector2i(SIZE, SIZE),
					"the normal map is %d x %d, got %s" % [SIZE, SIZE, normal.get_size() if normal != null else Vector2i()])
			_check(AOMapModule.new().create_available({"normal": normal, "height": _main.maps["height"]}),
					"the AO box Create is enabled with the normal map, the source")
			_check(not AOMapModule.new().create_available({}), "the AO box Create is disabled with an empty store")
			_main.boxes[5].create_button.pressed.emit()
			_phase = PHASE_GEN_AO
			print("ao live: AO box Create, ~100 passes")
		PHASE_GEN_AO:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_AO_READY
		PHASE_AO_READY:
			if not _main._status.text.contains("ready"):
				return
			var ao: Image = _main.maps["ao"]
			_check(ao != null and ao.get_size() == Vector2i(SIZE, SIZE),
					"the AO map is %d x %d, got %s" % [SIZE, SIZE, ao.get_size() if ao != null else Vector2i()])
			_base_mean = _mean(ao)
			print("ao live: AO mean %.3f" % _base_mean)
			_check(_base_mean > 0.35 and _base_mean < 0.95,
					"the stone wall's AO is mid-grey at the defaults, mean %.3f" % _base_mean)
			_check(_min(ao) >= 0.0 and _max(ao) <= 1.0, "the AO map is in 0..1, the saturate rule")
			# The AO Create makes the AO map the mesh preview, the same rule
			# as every box Create: the mesh shows the created map.
			_check(_main._mesh_map == "ao", "the mesh shows the AO map, mesh map %s" % [_main._mesh_map])
			var texture: ImageTexture = _main._mesh_material.get_shader_parameter("map")
			_check(texture != null and Vector2i(texture.get_size()) == ao.get_size(),
					"the mesh material shows the AO map texture")
			# The panel, read through its exported widget refs. The AO window
			# has no reveal slider, so the panel reports the split disabled
			# and has no preview signal at all.
			_panel = _main._panel_slot.get_child(0) as Control
			_check(_panel is AOPanel, "the AO panel slots in: %s" % [_panel.name])
			_check_bindings(_panel)
			# AO pixel Spread 100 widens the cone. The mean's direction is
			# resolution-dependent: the probe measured it rising at 16 px (the
			# cone wraps the tile, AO.y saturates), falling at 512 px (the
			# wider reach decorrelates the normal dot term). What is fixed is
			# that the slider changes the map, so the check is that the mean
			# moves measurably, and that restoring the slider returns the base.
			_panel.spread_slider.value = 100.0
			_phase = PHASE_SPREAD
			print("ao live: AO pixel Spread to 100")
		PHASE_SPREAD:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SPREAD_READY
		PHASE_SPREAD_READY:
			if not _main._status.text.contains("ready"):
				return
			var strong: float = _mean(_main.maps["ao"])
			_check(absf(strong - _base_mean) > 0.002,
					"AO pixel Spread 100 changes the AO map, %.3f -> %.3f" % [_base_mean, strong])
			_panel.spread_slider.value = 50.0
			_phase = PHASE_SPREAD_RESTORE
			print("ao live: spread back to 50, mean %.3f" % strong)
		PHASE_SPREAD_RESTORE:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SPREAD_RESTORE_READY
		PHASE_SPREAD_RESTORE_READY:
			if not _main._status.text.contains("ready"):
				return
			var base: float = _mean(_main.maps["ao"])
			_check(absf(base - _base_mean) < 0.02,
					"restoring the spread returns the base map, %.3f vs %.3f" % [base, _base_mean])
			# "AO influence of height map" 0 (Unity blend 0) means the height
			# map is ignored, so the AO is pure normal: on the stone wall the
			# plate gets the full sky, so the mean rises toward open-sky value.
			_panel.blend_slider.value = 0.0
			_phase = PHASE_BLEND
			print("ao live: blend off")
		PHASE_BLEND:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BLEND_READY
		PHASE_BLEND_READY:
			if not _main._status.text.contains("ready"):
				return
			var pure: float = _mean(_main.maps["ao"])
			_check(pure > _base_mean,
					"height blend off raises the mean AO on the stone wall, %.3f -> %.3f" % [_base_mean, pure])
			_panel.blend_slider.value = 1.0
			_phase = PHASE_BLEND_RESTORE
			print("ao live: blend back on, mean %.3f" % pure)
		PHASE_BLEND_RESTORE:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BLEND_RESTORE_READY
		PHASE_BLEND_RESTORE_READY:
			if not _main._status.text.contains("ready"):
				return
			var base: float = _mean(_main.maps["ao"])
			_check(absf(base - _base_mean) < 0.02,
					"restoring the blend returns the base map, %.3f vs %.3f" % [base, _base_mean])
			# AO Power 5 pushes the mid-grey AO darker. The final grade lives
			# in the combine pass, so a slider change re-runs the chain the
			# way the debounced drag does.
			_panel.contrast_slider.value = 5.0
			_phase = PHASE_CONTRAST
			print("ao live: AO Power to 5")
		PHASE_CONTRAST:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_CONTRAST_READY
		PHASE_CONTRAST_READY:
			if not _main._status.text.contains("ready"):
				return
			_dark_mean = _mean(_main.maps["ao"])
			_check(_dark_mean < _base_mean,
					"AO Power 5 pushes the mean AO down, %.3f -> %.3f" % [_base_mean, _dark_mean])
			# AO Bias 0.3 lifts it back up.
			_panel.bias_slider.value = 0.3
			_phase = PHASE_BIAS
			print("ao live: AO Bias to 0.3")
		PHASE_BIAS:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BIAS_READY
		PHASE_BIAS_READY:
			if not _main._status.text.contains("ready"):
				return
			var lifted: float = _mean(_main.maps["ao"])
			_check(lifted > _dark_mean,
					"AO Bias 0.3 lifts the mean AO, %.3f -> %.3f" % [_dark_mean, lifted])
			# Restore the grade: contrast back, then bias back. The chain is
			# deterministic, so the base settings give the base map.
			_panel.contrast_slider.value = 1.0
			_panel.bias_slider.value = 0.0
			_phase = PHASE_BIAS_RESTORE
			print("ao live: restoring the grade")
		PHASE_BIAS_RESTORE:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BIAS_RESTORE_READY
		PHASE_BIAS_RESTORE_READY:
			if not _main._status.text.contains("ready"):
				return
			var base: float = _mean(_main.maps["ao"])
			_check(absf(base - _base_mean) < 0.02,
					"restoring the grade returns the base map, %.3f vs %.3f" % [base, _base_mean])
			_check(_main.modules["ao"].settings()["final_contrast"] == 1.0,
					"the sliders write through into the module settings")
			_check(_main.modules["ao"].settings()["final_bias"] == 0.0,
					"the bias slider writes through into the module settings")
			# The Set button is the apply_requested signal the shell listens
			# for, so the emit runs the apply path the way the user's click
			# does. The chain is deterministic, so the re-run lands the base
			# map again.
			_panel.set_button.pressed.emit()
			_phase = PHASE_SET
			print("ao live: Set as AO Map")
		PHASE_SET:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SET_READY
		PHASE_SET_READY:
			if not _main._status.text.contains("ready"):
				return
			var applied: float = _mean(_main.maps["ao"])
			_check(absf(applied - _base_mean) < 0.02,
					"the Set button re-runs the base chain, %.3f vs %.3f" % [applied, _base_mean])
			# "Show full Material" puts AO on the mesh as the engine's
			# Ambient Occlusion slot, the way Unity's AO preview multiplies
			# AO into the lit colour (`AO_From_Normal_Preview.shader`).
			_main._show_full_material_button.pressed.emit()
			_phase = PHASE_FULL
			print("ao live: Show full Material")
		PHASE_FULL:
			if not _main._status.text.contains("Showing full material"):
				return
			var full: StandardMaterial3D = _main._full_material
			_check(full.ao_enabled, "the full material switches AO on for the mesh")
			var texture: ImageTexture = full.ao_texture
			_check(texture != null, "the full material's AO slot holds the AO map")
			if texture != null:
				_check(Vector2i(texture.get_size()) == _main.maps["ao"].get_size(),
						"the AO slot texture is the map, %s vs %s" % [Vector2i(texture.get_size()), _main.maps["ao"].get_size()])
			_check(full.ao_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED,
					"the AO slot reads the map's red channel, Materialize's greyscale packing, got %d" % [full.ao_texture_channel])
			_check(full.roughness_texture == null,
					"the AO-only store leaves the roughness slot empty")
			# Clear empties the map, the feature flag goes off, and the slot
			# samples the material's default.
			_main.boxes[5].clear_button.pressed.emit()
			_check(_main.maps["ao"] == null, "Clear empties the AO map")
			_check(not _main._full_material.ao_enabled,
					"the full material switches AO off when the map is cleared")
			_check(_main._full_material.ao_texture == null, "the cleared AO slot is empty")
			_check(AOMapModule.new().create_available({"normal": _main.maps["normal"]}),
					"the AO box Create is enabled with the normal map, the source")
			_check(not AOMapModule.new().create_available({"height": _main.maps["height"]}),
					"the AO box Create is disabled with a height-only store")
			_main.boxes[5].create_button.pressed.emit()
			_phase = PHASE_REGEN
			print("ao live: AO box Create again, checking the groove")
		PHASE_REGEN:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_REGEN_READY
		PHASE_REGEN_READY:
			if not _main._status.text.contains("ready"):
				return
			var mean: float = _mean(_main.maps["ao"])
			_check(absf(mean - _base_mean) < 0.02,
					"the AO map returns after clearing the box, %.3f vs %.3f" % [mean, _base_mean])
			var groove: float = _column_mean(_main.maps["ao"], GROOVE_X)
			var plate: float = _column_mean(_main.maps["ao"], PLATE_X)
			_check(groove < plate,
					"the groove column is darker than the flat plate column, %.3f vs %.3f" % [groove, plate])
			print("ao live: %d frames, groove %.3f, plate %.3f" % [_frames, groove, plate])
			for f in _failures:
				print(f)
			if _failures.size() == 0:
				print("all checks pass")
			else:
				print("%d failures" % _failures.size())
			get_tree().quit(_failures.size())

## Every AO panel widget, reached through the panel's exported refs: the
## slider ranges, the defaults Unity opens the window with, the labels, the
## Set button, and the signals the shell listens for. The AO window has no
## reveal slider, so the panel has no preview signal and reports the split
## disabled, and the tool samples no colours, so it has no colour picker.
func _check_bindings(panel: Control) -> void:
	var rows: Array = panel._slider_rows()
	_check(rows.size() == 5, "the AO panel has five settings rows")
	var want := [
		["spread", 10.0, 100.0, 50.0],
		["depth", 0.0, 256.0, 100.0],
		["blend", 0.0, 1.0, 1.0],
		["final_contrast", 0.1, 10.0, 1.0],
		["final_bias", -1.0, 1.0, 0.0],
	]
	for i in rows.size():
		var slider: Slider = rows[i][0]
		var label: Label = rows[i][1]
		var key: String = rows[i][2][0]
		var spec: Array = want[i]
		_check(slider.min_value == spec[1] and slider.max_value == spec[2],
				"%s range matches the Unity slider, got %.2f..%.2f" % [key, slider.min_value, slider.max_value])
		_check(is_equal_approx(slider.value, spec[3]),
				"%s default is %.2f, got %.2f" % [key, spec[3], slider.value])
		_check(is_equal_approx(_main.modules["ao"].settings()[key], spec[3]),
				"%s default is in the settings" % key)
		_check(label.text == "%.2f" % spec[3], "%s label reads through the exported ref" % key)
	_check(panel.set_button.text == "Set as AO Map", "the Set button is labelled for the AO map")
	_check(panel.has_signal("settings_changed"), "the panel reports settings changes")
	_check(panel.has_signal("apply_requested"), "the panel reports Apply")
	_check(not panel.has_signal("preview_changed"),
			"the AO window has no reveal slider, so the panel has no preview signal")
	_check(not panel.has_signal("color_pick_requested"),
			"the AO window has no colour picker, so the panel has none")
	_check(not AOMapModule.new().preview_split(), "the AO preview is the map plain, no split reveal")

func _mean(image: Image) -> float:
	var total: float = 0.0
	var size: Vector2i = image.get_size()
	for y in size.y:
		for x in size.x:
			total += image.get_pixelv(Vector2i(x, y)).r
	return total / float(size.x * size.y)

func _min(image: Image) -> float:
	var lowest := 1.0
	for y in image.get_size().y:
		for x in image.get_size().x:
			lowest = minf(lowest, image.get_pixelv(Vector2i(x, y)).r)
	return lowest

func _max(image: Image) -> float:
	var highest := 0.0
	for y in image.get_size().y:
		for x in image.get_size().x:
			highest = maxf(highest, image.get_pixelv(Vector2i(x, y)).r)
	return highest

func _column_mean(image: Image, x: int) -> float:
	var total: float = 0.0
	for y in image.get_size().y:
		total += image.get_pixelv(Vector2i(x, y)).r
	return total / float(image.get_size().y)

func _check(condition: bool, what: String) -> void:
	if not condition:
		_fail(what)

func _fail(what: String) -> void:
	_failures.append("FAIL: " + what)
	push_error(what)
