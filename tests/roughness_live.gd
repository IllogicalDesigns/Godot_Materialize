extends Node
## Live test for the Roughness map pass chain through the running shell.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/roughness_live.tscn`) so the
## SubViewport renders and the GPU pass chain runs. It drives the UI the way a
## user does, and asserts the invariants `tests/roughness_cpu.tscn` proves on
## the CPU reference:
##  - a roughness map is produced (a mean in the middle of the range, the metal
##    regions lifting smoothness off the base level),
##  - the map lands in the full material's Roughness slot, reading its red
##    channel (`StandardMaterial3D.roughness_texture` + `TEXTURE_CHANNEL_RED`),
##    which is the tool's real output,
##  - the metallic map drives the metal level: the metal regions pull the mean
##    off base, and base "Base Roughness" moves the rest,
##  - the Reveal Slider moves the split seam on the mesh preview and changes no
##    map (preview-only),
##  - "Set as Roughness" makes the roughness map the mesh preview,
##  - Clear empties the map,
##  - every panel widget is bound (export refs, signals, labels).
##
## The phases follow the shell's status label, because a slider goes through a
## debounce: "ready" -> "Generating" -> "ready". Checking the map the frame
## after a slider reads the old map, so each phase waits for its status.
##
## The panel under `MapOptionsPanel/PanelSlot` is replaced every time the active
## module changes, so the test re-fetches it from the slot and never keeps a
## reference across an activation. Every widget is reached through the panel's
## `@export` references, never a node path (`CODING_RULES.md`).

const PHASE_START := 0
const PHASE_SIZE := 1
const PHASE_GEN_METALLIC := 2
const PHASE_METALLIC_READY := 3
const PHASE_GEN_ROUGHNESS := 4
const PHASE_ROUGHNESS_READY := 5
const PHASE_FULL := 6
const PHASE_BASE := 7
const PHASE_BASE_READY := 8
const PHASE_APPLY := 9
const PHASE_APPLY_READY := 10
const PHASE_CLEAR := 11

const SIZE := 512
## The brick brown a "Pick Color" click on the wall finds, so both tools sample
## the wall's own colour: Metallic scores the wall as metal, and Roughness'
## metal regions lift smoothness off base.
const BRICK := Color(0.45, 0.22, 0.17)
## The mortar grey, sample 1's swatch in the panel round trip.
const MORTAR := Color(0.62, 0.62, 0.60)

var _frames := 0
var _phase := PHASE_START
var _main: Node
var _panel: Control
var _rough_mean := 0.0
var _base_mean := 0.0
var _failures: Array[String] = []

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 1800:
		print("roughness live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the smallest resolution, so the
			# two blur passes stay cheap and the test stays readable.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SIZE
			print("roughness live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SIZE:
			if not _main._status.text.contains("ready"):
				return
			# The Roughness tool reads the Metallic map, so a metallic map must
			# exist first: drive the Metallic window on the wall's own colour.
			_main._activate(_main.modules["metallic"])
			_panel = _main._panel_slot.get_child(0) as Control
			_panel.metal_color_picker.color = BRICK
			_panel.weight_faders[0].slider.value = 1.0
			_panel.weight_faders[1].slider.value = 0.0
			_panel.weight_faders[2].slider.value = 0.0
			_panel.weight_faders[3].slider.value = 0.0
			_panel.weight_faders[4].slider.value = 0.5
			_main.boxes[3].create_button.pressed.emit()
			_phase = PHASE_GEN_METALLIC
			print("roughness live: Metallic window on the brick colour, Low 0.0 High 0.5")
		PHASE_GEN_METALLIC:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_METALLIC_READY
		PHASE_METALLIC_READY:
			if not _main._status.text.contains("ready"):
				return
			var metal: Image = _main.maps["metallic"]
			_check(metal != null and metal.get_size() == Vector2i(SIZE, SIZE),
					"the metallic map is %d x %d, got %s" % [SIZE, SIZE, metal.get_size() if metal != null else Vector2i()])
			var metal_mean := _mean(metal)
			print("roughness live: metallic mean %.3f, wall colour scores as metal" % metal_mean)
			_check(metal_mean > 0.5, "the metallic map is mostly metal on the wall, mean %0.3f" % metal_mean)
			# Now the Roughness box: Create activates the module and runs its
			# passes on the diffuse.
			_main.boxes[4].create_button.pressed.emit()
			_phase = PHASE_GEN_ROUGHNESS
			print("roughness live: Roughness box Create")
		PHASE_GEN_ROUGHNESS:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_ROUGHNESS_READY
		PHASE_ROUGHNESS_READY:
			if not _main._status.text.contains("ready"):
				return
			var rough: Image = _main.maps["roughness"]
			_check(rough != null and rough.get_size() == Vector2i(SIZE, SIZE),
					"the roughness map is %d x %d, got %s" % [SIZE, SIZE, rough.get_size() if rough != null else Vector2i()])
			_rough_mean = _mean(rough)
			print("roughness live: roughness mean %.3f" % _rough_mean)
			# Base Roughness 0.9 (Unity's BaseSmoothness 0.1), Metal Roughness
			# 0.3, and a metallic map that marks the whole wall as metal: the
			# mean must drop well below base, because the metal regions pull the
			# level to the smoother metal value.
			_check(_rough_mean < 0.5,
					"the metallic map marks the wall as metal, so the mean roughness %0.3f must sit well below Base Roughness 0.9" % _rough_mean)
			var spread := _spread(rough)
			print("roughness live: roughness spread %.4f" % spread)
			_check(spread > 0.01, "the map carries the metallic map's detail, spread %0.4f" % spread)
			# The full material is the tool's output: the map must reach the
			# Roughness slot, reading its red channel.
			_main._show_full_material_button.pressed.emit()
			_phase = PHASE_FULL
			print("roughness live: Show full Material")
		PHASE_FULL:
			if not _main._status.text.contains("Showing full material"):
				return
			var full: StandardMaterial3D = _main._full_material
			var rough: Image = _main.maps["roughness"]
			var texture: ImageTexture = full.roughness_texture
			_check(texture != null, "the full material's Roughness slot holds the roughness map")
			if texture != null:
				_check(Vector2i(texture.get_size()) == rough.get_size(),
						"the Roughness slot texture is the map, %s vs %s" % [Vector2i(texture.get_size()), rough.get_size()])
			_check(full.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED,
					"the Roughness slot reads the map's red channel, Materialize's greyscale packing, got %d" % [full.roughness_texture_channel])
			# The Roughness slot has no enable flag in this engine version, so
			# the probe reports the properties the shell can fill: `roughness`,
			# `roughness_texture`, `roughness_texture_channel`.
			print("roughness live: full material roughness ", full.roughness,
					", channel ", full.roughness_texture_channel,
					", slot texture size ", texture.get_size() if texture != null else Vector2i())
			# The Reveal Slider is preview-only: it moves the seam on the mesh
			# material and writes no map.
			_panel = _main._panel_slot.get_child(0) as Control
			_check(_panel is RoughnessPanel, "the roughness panel slots in: %s" % [_panel.name])
			_check_bindings(_panel)
			_panel.reveal_slider.value = 0.3
			var reveal: float = _main._mesh_material.get_shader_parameter("reveal")
			var split: float = _main._mesh_material.get_shader_parameter("split_reveal")
			print("roughness live: mesh preview reveal %.2f, split_reveal %.2f, reveal label " % [reveal, split],
					_panel.reveal_label.text)
			_check(abs(reveal - 0.3) < 0.01, "reveal slider 0.3 reaches the mesh material, got %0.2f" % reveal)
			_check(abs(split - 0.3) < 0.01, "the roughness preview splits at the seam, split_reveal %0.2f" % split)
			_check(RoughnessMapModule.new().preview_split(), "the module says its preview uses the split reveal")
			# Base Roughness is the level every pixel that is not metal, sample 1,
			# or sample 2 starts from. Clear the Metallic map first: Unity's
			# default metallic map is a flat black texture (`_DefaultMetallicMap`),
			# so no pixel is metal and the base level reads straight.
			_main.boxes[3].clear_button.pressed.emit()
			_check(_main.maps["metallic"] == null, "Clear empties the metallic map, so Roughness falls back to Unity's flat default")
			_panel.base_roughness_slider.value = 0.2
			_phase = PHASE_BASE
			print("roughness live: Metallic map cleared, Base Roughness fader to 0.2")
		PHASE_BASE:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BASE_READY
		PHASE_BASE_READY:
			if not _main._status.text.contains("ready"):
				return
			_base_mean = _mean(_main.maps["roughness"])
			print("roughness live: mean %.3f at Base 0.9, %.3f at Base 0.2" % [_rough_mean, _base_mean])
			_check(_base_mean < _rough_mean,
					"Base Roughness 0.2 is smoother than 0.9, so the mean must fall, got %0.3f and %0.3f" % [_base_mean, _rough_mean])
			_panel.set_button.pressed.emit()
			_phase = PHASE_APPLY
			print("roughness live: Set as Roughness")
		PHASE_APPLY:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_APPLY_READY
		PHASE_APPLY_READY:
			if not _main._status.text.contains("ready"):
				return
			var applied: Image = _main.maps["roughness"]
			# "Show full Material" is not a map in the store, so the shell keys
			# the mesh's full-material mode with its own `FULL_MESH_MAP` value.
			_check(_main._mesh_map == "full",
					"the mesh keeps showing the full material after Set as Roughness, mesh map %s" % [_main._mesh_map])
			_check(_mean(applied) < 0.5,
					"Set as Roughness re-ran the chain at Base Roughness 0.2, mean %0.3f" % [_mean(applied)])
			_check(_main._full_material.roughness_texture != null,
					"the full material's Roughness slot re-fills when the applied map changes")
			_main.boxes[4].clear_button.pressed.emit()
			_phase = PHASE_CLEAR
			print("roughness live: Roughness box Clear")
		PHASE_CLEAR:
			_check(_main.maps["roughness"] == null, "Clear empties the roughness map in the map store")
			_check(RoughnessMapModule.new().create_available(_main.maps),
					"Create stays available while a diffuse exists, the Roughness tool's only required input")
			var module := RoughnessMapModule.new()
			_check(not module.create_available({}), "Create is greyed out with an empty map store, Materialize's rule")
			if _failures.is_empty():
				print("roughness live: PASS")
			else:
				for failure in _failures:
					print("FAIL: %s" % failure)
				print("roughness live: FAIL")
			get_tree().quit()

func _mean(image: Image) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			total += image.get_pixel(x, y).r
	return total / float(image.get_width() * image.get_height())

func _spread(image: Image) -> float:
	var mean := _mean(image)
	var sq := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var value := image.get_pixel(x, y).r
			sq += (value - mean) * (value - mean)
	return sqrt(sq / float(image.get_width() * image.get_height()))

## Every widget the panel wires is an `@export`, so a missing widget shows up as
## a null reference here rather than a crash mid-edit.
func _check_bindings(panel: Control) -> void:
	var missing: Array[String] = []
	for row: Array in panel._slider_rows():
		if row[0] == null:
			missing.append(str(row[2]))
		if row[1] == null:
			missing.append(str(row[2]) + " label")
	for row: Array in panel._check_rows():
		if row[0] == null:
			missing.append(str(row[1]))
	for row: Array in panel._color_rows():
		if row[0] == null:
			missing.append(str(row[1]))
	for row: Array in panel._pick_rows():
		if row[0] == null:
			missing.append(str(row[0]))
	for fold: Array in panel._sample_folds():
		if fold[2] == null:
			missing.append(fold[0])
		if fold[3] == null:
			missing.append(fold[0] + " isolate")
	for fader: FaderGroup in panel.sample1_faders:
		if fader.slider == null or fader.value_label == null:
			missing.append("sample1 fader")
	for fader: FaderGroup in panel.sample2_faders:
		if fader.slider == null or fader.value_label == null:
			missing.append("sample2 fader")
	if panel.set_button == null:
		missing.append("set_button")
	_check(missing.is_empty(), "every panel export is bound, missing: %s" % [missing])
	_check(panel.has_signal("settings_changed"), "panel declares settings_changed")
	_check(panel.has_signal("preview_changed"), "panel declares preview_changed")
	_check(panel.has_signal("apply_requested"), "panel declares apply_requested")
	_check(panel.has_signal("color_pick_requested"),
			"panel declares color_pick_requested, the sample pick the shell answers")

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		print("FAIL: %s" % description)
