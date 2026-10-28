extends Node
## Live regression test for switching back to a map that was created earlier.
##
## The bug: creating Normal, then Metallic, then pressing Normal's Create
## crashed the app with "Trying to assign invalid previously freed instance",
## because `_activate()` freed the outgoing panel while `_panels` kept a cached
## reference to it. The fix parks the outgoing panel hidden in
## `_panel_park` (`scenes/main.tscn`) so the cached panels stay in the tree.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/switch_live.tscn`) so the SubViewport
## renders and the GPU pass chains run. The phases follow the shell's status
## label, because a box's Create goes through the debounce:
## "ready" -> "Generating" -> "ready".
##
## Asserts:
##  - height -> normal -> metallic -> normal, the user's repro path, survives
##    every activation without a freed-instance crash,
##  - the panel cached for a map is the same instance when that map comes back
##    (instance id), and its slider state survives the switch,
##  - every cached panel is still a valid instance, parked hidden in the park,
##    one panel in the slot,
##  - switching back re-runs the chain on the parked panel's sliders, so the
##    map is regenerated on the settings the user left.
##
## Every widget the test drives is a shell `@export` reference, never a node
## path (`CODING_RULES.md`).

const SIZE := 512

const PHASE_START := 0
const PHASE_SIZE := 1
const PHASE_GEN_NORMAL := 2
const PHASE_NORMAL_READY := 3
const PHASE_SLIDERS := 4
const PHASE_SLIDERS_READY := 5
const PHASE_GEN_METALLIC := 6
const PHASE_METALLIC_READY := 7
const PHASE_BACK := 8
const PHASE_BACK_READY := 9
const PHASE_DONE := 10

## The slider the test sets on the normal panel before switching away, inside
## Unity's Slope Blur range (5..100).
const BLUR := 75.0
const REVEAL := 0.3

var _frames := 0
var _phase := PHASE_START
var _main: Node
var _normal_id := -1
var _failures: Array[String] = []

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 1800:
		print("switch live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the size the test measures, so
			# the chains run at their test cost.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SIZE
			print("switch live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SIZE:
			if not _main._status.text.contains("ready"):
				return
			# The repro path, step by step: the height module is active from
			# the start. Create the normal map.
			_main._on_box_button("create", "normal")
			_phase = PHASE_GEN_NORMAL
			print("switch live: creating the normal map")
		PHASE_GEN_NORMAL:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_NORMAL_READY
		PHASE_NORMAL_READY:
			if not _main._status.text.contains("ready"):
				return
			var panel: Control = _main._panel_slot.get_child(0) as Control
			_check(panel is NormalPanel, "normal panel slots in: %s" % [panel.name])
			_normal_id = _main._panels["normal"].get_instance_id()
			# Drive the panel as the user does, so there is state to preserve
			# across the switch.
			panel.slope_blur_slider.value = BLUR
			panel.reveal_slider.value = REVEAL
			_phase = PHASE_SLIDERS
			print("switch live: normal panel ", panel.name, ", Slope Blur ",
					panel.slope_blur_label.text, ", reveal ", panel.reveal_label.text)
		PHASE_SLIDERS:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SLIDERS_READY
		PHASE_SLIDERS_READY:
			if not _main._status.text.contains("ready"):
				return
			# Step two: create the metallic map, which frees nothing now.
			_main._on_box_button("create", "metallic")
			_phase = PHASE_GEN_METALLIC
			print("switch live: creating the metallic map")
		PHASE_GEN_METALLIC:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_METALLIC_READY
		PHASE_METALLIC_READY:
			if not _main._status.text.contains("ready"):
				return
			var slot: Control = _main._panel_slot.get_child(0) as Control
			_check(slot is MetallicPanel, "metallic panel slots in: %s" % [slot.name])
			# The height panel, the normal panel, and the metallic panel: all
			# cached panels stay valid in the park, hidden, never freed.
			_check(is_instance_valid(_main._panels["height"]),
					"the height panel is a valid instance while metallic is active")
			_check(is_instance_valid(_main._panels["normal"]),
					"the normal panel is a valid instance while metallic is active")
			_check(_main._panel_park.get_child_count() == 2,
					"the parked panels sit hidden in the park, got %d"
					% [_main._panel_park.get_child_count()])
			_check(_main._panel_park.get_child(0) == _main._panels["height"]
					and _main._panel_park.get_child(1) == _main._panels["normal"],
					"height then normal are parked in the order they left the slot")
			_check(not _main._panel_park.visible, "the park is hidden")
			_check(not _main._panel_park.get_child(0).visible
					and not _main._panel_park.get_child(1).visible,
					"the parked panels are hidden")
			# Step three: go back to the normal map. This used to crash.
			_main._on_box_button("create", "normal")
			_phase = PHASE_BACK
			print("switch live: going back to the normal map")
		PHASE_BACK:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_BACK_READY
		PHASE_BACK_READY:
			if not _main._status.text.contains("ready"):
				return
			var back: Control = _main._panel_slot.get_child(0) as Control
			_check(back is NormalPanel, "the normal panel slots back in: %s" % [back.name])
			_check(back.get_instance_id() == _normal_id,
					"the panel that comes back is the cached instance, id %d vs %d"
					% [back.get_instance_id(), _normal_id])
			_check(_main._panel_slot.get_child_count() == 1,
					"one panel is in the slot, got %d" % [_main._panel_slot.get_child_count()])
			_check(back.slope_blur_slider.value == BLUR,
					"the normal panel's Slope Blur survives the switch, got %0.2f"
					% [back.slope_blur_slider.value])
			_check(back.reveal_slider.value == REVEAL,
					"the normal panel's reveal survives the switch, got %0.2f"
					% [back.reveal_slider.value])
			_check(_main.modules["normal"].settings()["slope_blur"] == BLUR,
					"the settings Dictionary still carries Slope Blur %0.2f, got %s"
					% [BLUR, _main.modules["normal"].settings()["slope_blur"]])
			_check(abs(_main._mesh_material.get_shader_parameter("reveal") - REVEAL) < 0.01,
					"the reveal uniform re-read the parked panel, got %0.2f"
					% [_main._mesh_material.get_shader_parameter("reveal")])
			_check(_main._mesh_map == "normal", "the normal map is the mesh map, got %s" % [_main._mesh_map])
			var normal_map: Image = _main.maps["normal"]
			_check(normal_map.get_size() == Vector2i(SIZE, SIZE),
					"the normal map is ready at %d after coming back, got %s"
					% [SIZE, normal_map.get_size()])
			_check(is_instance_valid(_main._panels["height"]),
					"the height panel is still valid after coming back")
			_check(_main._panel_park.get_child_count() == 2,
					"the panels that left the slot are parked, got %d" % [_main._panel_park.get_child_count()])
			_check(_main._panel_park.get_child(0) == _main._panels["height"]
					and _main._panel_park.get_child(1) == _main._panels["metallic"],
					"the park holds height then metallic, in the order they left the slot")
			_phase = PHASE_DONE
			print("switch live: back to normal without a crash")
		PHASE_DONE:
			if _failures.is_empty():
				print("switch live: PASS")
			else:
				for failure in _failures:
					print("FAIL: %s" % failure)
				print("switch live: FAIL")
			get_tree().quit()

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		print("FAIL: %s" % description)
