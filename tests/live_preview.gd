extends Node
## End-to-end check of the live mesh output: instantiate the real main scene,
## let the Height module generate from the stone test pattern, then verify the
## `MeshInstance3D` material has the generated map, print its statistics, and
## save both the map and a window screenshot for inspection.
##
## It also drives the panel the way a user does, and checks the whole chain:
##   - the Height Reveal Slider writes settings and the mesh material's `reveal`
##     uniform (a preview control, so no pass chain runs),
##   - the "Details" weight preset writes settings, fires the debounce, runs the
##     pass chain, and updates the map box preview. The checksum must move, which
##     is what proves the preset reached the shader.
##
## The phases follow the shell's status label, because the preset goes through a
## debounce timer: "ready" -> "Generating" -> "ready". Checking the map the frame
## after a preset click reads the old map, so each phase waits for its status.
##
## Needs a real display and GPU:
##   DISPLAY=:1 godot --path . res://tests/live_preview.tscn
##
## The GPU result should match the CPU reference in `tests/height_cpu.tscn`
## (stone result min 0.401 max 0.634 mean 0.498), which is the point of the check.

var _main: Node3D
var _frames := 0
var _phase := 0
const PHASE_FIRST_READY := 0
const PHASE_PRESET_GENERATING := 1
const PHASE_PRESET_READY := 2
const PHASE_ARTIFACTS := 3

## Checksum of the first generated map, so the preset run can be compared.
var _first_checksum := 0.0

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 900:
		print("live preview: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return

	match _phase:
		PHASE_FIRST_READY:
			if not _main._status.text.contains("ready"):
				return
			_first_phase()
		PHASE_PRESET_GENERATING:
			# The shell debounces slider writes, so "Generating" is the signal
			# that the preset started a pass chain.
			if _main._status.text.contains("Generating"):
				_phase = PHASE_PRESET_READY
		PHASE_PRESET_READY:
			if not _main._status.text.contains("ready"):
				return
			_preset_phase()
		PHASE_ARTIFACTS:
			_artifacts()

func _first_phase() -> void:
	var map: Image = _main.maps["height"]
	var texture: ImageTexture = _main._mesh_material.get_shader_parameter("map")
	print("status: ", _main._status.text)
	print("map on mesh: ", texture != null, " size=",
		(texture.get_size() if texture != null else Vector2i(0, 0)))
	print("reveal uniform on mesh material: ", _main._mesh_material.get_shader_parameter("reveal"))
	print("active panel in MapOptionsPanel: ", _main._panel_slot.get_child_count(),
		" child(ren): ", (_main._panel_slot.get_child(0) as Node).name
		if _main._panel_slot.get_child_count() > 0 else "none")
	if map != null:
		_first_checksum = _checksum(map)
		print("GPU height map: ", _stats(map))
		print("expect min 0.401 max 0.634 mean 0.498 from the CPU reference")
	# The Reveal slider is a preview control: setting it must write settings and
	# the material uniform without starting a pass chain.
	var panel: Control = _main._panel_slot.get_child(0)
	var reveal: HSlider = panel.get_node("Column/RevealGroup/Reveal")
	reveal.value = 0.35
	print("reveal slider -> settings ", _main._active.settings()["reveal"],
		", material uniform ", _main._mesh_material.get_shader_parameter("reveal"))
	# A preset click goes through settings -> debounce -> pass chain -> box preview.
	panel.get_node("Column/WeightGroup/Row/Presets/Details").emit_signal("pressed")
	_phase = PHASE_PRESET_GENERATING

func _preset_phase() -> void:
	var weights: Array = _main._active.settings()["weights"]
	var panel: Control = _main._panel_slot.get_child(0)
	var slider_values: Array = []
	for fader in ["W6", "W5", "W4", "W3", "W2", "W1", "W0"]:
		slider_values.append((panel.get_node("Column/WeightGroup/Row/Faders/" + fader + "/Slider") as Slider).value)
	print("after Details preset, status: ", _main._status.text)
	print("settings weights (index 0 = Blur0, index 6 = Blur6): ", weights)
	print("expect [0.7, 0.4, 0.3, 0.5, 0.8, 0.9, 0.7] from HeightFromDiffuseSettings detail preset")
	print("fader W6..W0 slider values: ", slider_values)
	var box_preview: TextureRect = (_main._boxes["height"] as MapBox).get_node("Box/Preview")
	print("height map box preview texture: ", box_preview.texture,
		" size=", (box_preview.texture.get_size() if box_preview.texture != null else Vector2i(0, 0)))
	var map: Image = _main.maps["height"]
	print("height map after preset: ", _stats(map))
	print("checksum before preset: %.6f" % _first_checksum)
	print("expect the checksum to move: the preset changed the weight uniforms")
	_phase = PHASE_ARTIFACTS

func _artifacts() -> void:
	var map: Image = _main.maps["height"]
	_main._set_status("Saving test artefacts.")
	map.save_png("user://live_preview_height.png")
	var screenshot: Image = get_tree().root.get_texture().get_image()
	screenshot.save_png("user://live_preview_window.png")
	print("Wrote user://live_preview_height.png and user://live_preview_window.png")
	print("On Linux these are under ~/.local/share/godot/app_userdata/materialize/")
	get_tree().quit()

func _checksum(map: Image) -> float:
	# Godot 4.7 `Image` has no lock()/unlock(), so the pixel loop reads directly.
	var size: Vector2i = map.get_size()
	var total_sq := 0.0
	for y in range(size.y):
		for x in range(size.x):
			var value: float = map.get_pixel(x, y).r
			total_sq += value * value
	return total_sq / float(size.x * size.y)

func _stats(map: Image) -> String:
	var size: Vector2i = map.get_size()
	var minimum := 1e9
	var maximum := -1e9
	var total := 0.0
	var total_sq := 0.0
	for y in range(size.y):
		for x in range(size.x):
			var value: float = map.get_pixel(x, y).r
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
			total += value
			total_sq += value * value
	return "min %.3f max %.3f mean %.3f checksum %.6f" % [minimum, maximum,
		total / float(size.x * size.y), total_sq / float(size.x * size.y)]
