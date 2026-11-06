extends Node
## Live test for the Normal From Height pass chain through the running shell.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/normal_live.tscn`) so the
## SubViewport renders and the GPU pass chain runs. It drives the UI the way a
## user does, and asserts the invariants `tests/normal_cpu.tscn` proves on the
## CPU reference:
##  - a normal map is produced (mean blue well above 0.5: normals point up),
##  - red sits at neutral 0.5 (the signed convention, no light bias),
##  - the map carries relief detail (spread and `tilt` well above zero: `tilt`
##    is the mean length of the red/green deviation from neutral, so it is 0
##    on a flat map and grows with the normals leaning out of straight up),
##  - the Smooth preset gives flatter relief than the Crisp preset,
##  - "Set as Normal Map" re-runs the chain with the current sliders,
##  - the Normal Reveal Slider moves the seam on the mesh preview
##    (`is_normal` + `reveal` uniforms), which is preview-only,
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
const PHASE_CHOOSE := 2
const PHASE_GEN_SLIDERS := 3
const PHASE_SLIDERS_READY := 4
const PHASE_GEN_SMOOTH := 5
const PHASE_SMOOTH_READY := 6
const PHASE_GEN_CRISP := 7
const PHASE_CRISP_READY := 8
const PHASE_GEN_APPLY := 9
const PHASE_APPLY_READY := 10

const SIZE := 512

## The slider values the test drives, inside the Unity window's ranges:
## Slope Blur 75, Final Contrast 3, Shape Bias 0.5, the rest at defaults.
const BLUR := 75.0
const CONTRAST := 3.0
const SHAPE_BIAS := 0.5

## Statistics from the CPU reference (`tests/normal_cpu.tscn`) on the same
## stone test pattern at the same size, with the same sliders. The GPU chain
## must land within the tolerances, which is the point of the test: the same
## source, the same sliders and the same pass chain on the GPU have to give the
## same normal map. `tilt` is the mean length of the (red, green) deviation
## from neutral, the amount the normals lean: a flat source has tilt 0.
const CPU_STONE := {"mean_r": 0.503, "mean_g": 0.488, "mean_b": 0.976, "spread": 0.051, "tilt": 0.130}
const CPU_SMOOTH := {"mean_r": 0.503, "mean_g": 0.488, "mean_b": 0.987, "spread": 0.037, "tilt": 0.097}
const CPU_CRISP := {"mean_r": 0.505, "mean_g": 0.486, "mean_b": 0.918, "spread": 0.090, "tilt": 0.215}
const TOL_MEAN := 0.05
const TOL_SPREAD := 0.05
const TOL_TILT := 0.05
const MIN_SPREAD := 0.02
const MIN_TILT := 0.05

var _frames := 0
var _phase := PHASE_START
var _main: Node
var _panel: Control
var _stone: Dictionary = {}
var _smooth: Dictionary = {}
var _crisp: Dictionary = {}
var _applied: Dictionary = {}
var _failures: Array[String] = []


func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 1800:
		print("normal live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the smallest resolution, which
			# is the size the CPU reference measures, so the numbers line up.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SIZE
			print("normal live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SIZE:
			if not _main._status.text.contains("ready"):
				return
			_main._activate(_main.modules["normal"])
			_panel = _main._panel_slot.get_child(0) as Control
			_phase = PHASE_CHOOSE
		PHASE_CHOOSE:
			_check(_panel is NormalPanel, "normal panel slots in: %s" % [_panel.name])
			var missing: Array[String] = []
			for row: Array in _panel._fader_rows():
				if row[0] == null:
					missing.append(row[2][0])
				if row[1] == null:
					missing.append(str(row[2]))
			for row: Array in _panel._slider_rows():
				if row[0] == null:
					missing.append(str(row[2]))
				if row[1] == null:
					missing.append(str(row[2]) + " label")
			for row: Array in _panel._check_rows():
				if row[0] == null:
					missing.append(str(row[1]))
			for row: Array in _panel._preset_rows():
				if row[0] == null:
					missing.append(row[1])
			if _panel.set_button == null:
				missing.append("set_button")
			_check(missing.is_empty(), "every panel export is bound, missing: %s" % [missing])
			_check(_panel.has_signal("settings_changed"), "panel declares settings_changed")
			_check(_panel.has_signal("preview_changed"), "panel declares preview_changed")
			_check(_panel.has_signal("apply_requested"), "panel declares apply_requested")
			_check(not _panel.has_signal("color_pick_requested"),
					"panel has no color_pick_requested, which the shell guards on")
			var settings: Dictionary = _main.modules["normal"].settings()
			_check(settings["weights"].size() == 7, "settings carry the 7 equalizer weights")
			_check(settings["pre_contrast"] == 20.0, "Pre Contrast default is 20, got %s" % [settings["pre_contrast"]])
			_check(settings["final_contrast"] == 5.0, "Final Contrast default is 5, got %s" % [settings["final_contrast"]])
			print("normal live: panel ", _panel.name, ", labels: Slope Blur ",
					_panel.slope_blur_label.text, ", Final Contrast ", _panel.final_contrast_label.text,
					", Shape Bias ", _panel.shape_bias_label.text,
					", fader rightmost ", _panel.weight_faders[6].value_label.text,
					", Shape from Diffuse checked: ", _panel.use_diffuse_check.button_pressed)
			print("normal live: status '", _main._status.text, "', mesh map: ", _main._mesh_map)
			# Drive the sliders as the user does: writing a slider value fires
			# value_changed, which writes settings and asks the shell to
			# regenerate.
			_panel.slope_blur_slider.value = BLUR
			_panel.final_contrast_slider.value = CONTRAST
			_panel.shape_bias_slider.value = SHAPE_BIAS
			_panel.reveal_slider.value = 0.3
			_phase = PHASE_GEN_SLIDERS
			print("normal live: sliders Slope Blur %.1f, Final Contrast %.1f, Shape Bias %.2f, reveal 0.3"
					% [BLUR, CONTRAST, SHAPE_BIAS])
		PHASE_GEN_SLIDERS:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SLIDERS_READY
		PHASE_SLIDERS_READY:
			if not _main._status.text.contains("ready"):
				return
			_stone = _stats()
			var live: Image = _main.maps["normal"]
			print("normal live stone -> mean %.3f %.3f %.3f, spread %.4f, tilt %.4f  (CPU reference %s)"
					% [_stone["mean_r"], _stone["mean_g"], _stone["mean_b"], _stone["spread"],
					_stone["tilt"], CPU_STONE])
			_check(live.get_size() == Vector2i(SIZE, SIZE), "live map is %d x %d, got %s" % [SIZE, SIZE, live.get_size()])
			_check(abs(_stone["mean_b"] - CPU_STONE["mean_b"]) < TOL_MEAN,
					"mean blue %0.3f is near the CPU reference %0.3f" % [_stone["mean_b"], CPU_STONE["mean_b"]])
			_check(abs(_stone["mean_r"] - CPU_STONE["mean_r"]) < TOL_MEAN,
					"mean red %0.3f is near the CPU reference %0.3f" % [_stone["mean_r"], CPU_STONE["mean_r"]])
			_check(_stone["spread"] > MIN_SPREAD, "stone spread %0.3f has relief" % _stone["spread"])
			_check(_stone["tilt"] > MIN_TILT, "stone tilt %0.3f means the normals lean out of flat" % _stone["tilt"])
			_check(abs(_stone["spread"] - CPU_STONE["spread"]) < TOL_SPREAD,
					"stone spread %0.3f matches the CPU reference %0.3f" % [_stone["spread"], CPU_STONE["spread"]])
			_check(abs(_stone["tilt"] - CPU_STONE["tilt"]) < TOL_TILT,
					"stone tilt %0.3f matches the CPU reference %0.3f" % [_stone["tilt"], CPU_STONE["tilt"]])
			# The reveal slider is preview-only: it moves the seam on the mesh,
			# and the mesh shader shades the normal map (`is_normal`).
			var reveal: float = _main._mesh_material.get_shader_parameter("reveal")
			var is_normal: float = _main._mesh_material.get_shader_parameter("is_normal")
			print("normal live: mesh preview reveal %.2f, is_normal %.0f, reveal label " % [reveal, is_normal],
					_panel.reveal_label.text)
			_check(abs(reveal - 0.3) < 0.01, "reveal slider 0.3 reaches the mesh material, got %0.2f" % reveal)
			_check(abs(is_normal - 1.0) < 0.01, "the mesh preview shades the normal map, is_normal %0.1f" % is_normal)
			_panel.preset_smooth_button.pressed.emit()
			var weights: Array = _main.modules["normal"].settings()["weights"]
			_check(weights == [0.1, 0.15, 0.25, 0.6, 0.9, 1.0, 1.0],
					"Smooth preset writes the Unity window's weights %s" % [weights])
			_check(_panel.weight_faders[6].slider.value == 0.1 and _panel.weight_faders[0].slider.value == 1.0,
					"the faders re-sync from the preset, coarse first")
			_phase = PHASE_GEN_SMOOTH
			print("normal live: Smooth preset weights %s" % [weights])
		PHASE_GEN_SMOOTH:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_SMOOTH_READY
		PHASE_SMOOTH_READY:
			if not _main._status.text.contains("ready"):
				return
			_smooth = _stats()
			print("normal live smooth -> mean %.3f %.3f %.3f, spread %.4f, tilt %.4f  (CPU reference %s)"
					% [_smooth["mean_r"], _smooth["mean_g"], _smooth["mean_b"], _smooth["spread"],
					_smooth["tilt"], CPU_SMOOTH])
			_check(abs(_smooth["spread"] - CPU_SMOOTH["spread"]) < TOL_SPREAD,
					"smooth spread %0.3f matches the CPU reference %0.3f" % [_smooth["spread"], CPU_SMOOTH["spread"]])
			_check(abs(_smooth["tilt"] - CPU_SMOOTH["tilt"]) < TOL_TILT,
					"smooth tilt %0.3f matches the CPU reference %0.3f" % [_smooth["tilt"], CPU_SMOOTH["tilt"]])
			_panel.preset_crisp_button.pressed.emit()
			_phase = PHASE_GEN_CRISP
			print("normal live: Crisp preset")
		PHASE_GEN_CRISP:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_CRISP_READY
		PHASE_CRISP_READY:
			if not _main._status.text.contains("ready"):
				return
			_crisp = _stats()
			print("normal live crisp -> mean %.3f %.3f %.3f, spread %.4f, tilt %.4f  (CPU reference %s)"
					% [_crisp["mean_r"], _crisp["mean_g"], _crisp["mean_b"], _crisp["spread"],
					_crisp["tilt"], CPU_CRISP])
			_check(_crisp["spread"] > MIN_SPREAD, "crisp spread %0.3f has relief" % _crisp["spread"])
			_check(_crisp["tilt"] > MIN_TILT, "crisp tilt %0.3f means the normals lean out of flat" % _crisp["tilt"])
			_check(_crisp["spread"] > _smooth["spread"],
					"crisp spread %0.3f is sharper-detail than smooth spread %0.3f" % [_crisp["spread"], _smooth["spread"]])
			_check(_crisp["tilt"] > _smooth["tilt"],
					"crisp tilt %0.3f leans more than smooth tilt %0.3f" % [_crisp["tilt"], _smooth["tilt"]])
			_check(abs(_crisp["spread"] - CPU_CRISP["spread"]) < TOL_SPREAD,
					"crisp spread %0.3f matches the CPU reference %0.3f" % [_crisp["spread"], CPU_CRISP["spread"]])
			_check(abs(_crisp["tilt"] - CPU_CRISP["tilt"]) < TOL_TILT,
					"crisp tilt %0.3f matches the CPU reference %0.3f" % [_crisp["tilt"], CPU_CRISP["tilt"]])
			# "Set as Normal Map" runs the chain again on the current sliders,
			# and makes the normal map the mesh preview.
			_panel.set_button.pressed.emit()
			_phase = PHASE_GEN_APPLY
			print("normal live: Set as Normal Map")
		PHASE_GEN_APPLY:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_APPLY_READY
		PHASE_APPLY_READY:
			if not _main._status.text.contains("ready"):
				return
			_applied = _stats()
			print("normal live after apply -> mean %.3f %.3f %.3f, spread %.4f, tilt %.4f"
					% [_applied["mean_r"], _applied["mean_g"], _applied["mean_b"], _applied["spread"],
					_applied["tilt"]])
			_check(_main._mesh_map == "normal", "the normal map is the mesh preview, mesh map %s" % [_main._mesh_map])
			_check(abs(_applied["mean_b"] - CPU_CRISP["mean_b"]) < TOL_MEAN,
					"applied mean blue %0.3f is near the crisp CPU reference %0.3f" % [_applied["mean_b"], CPU_CRISP["mean_b"]])
			if _failures.is_empty():
				print("normal live: PASS")
			else:
				for failure in _failures:
					print("FAIL: %s" % failure)
				print("normal live: FAIL")
			get_tree().quit()


func _stats() -> Dictionary:
	var live: Image = _main.maps["normal"]
	var size: Vector2i = live.get_size()
	var count := float(size.x * size.y)
	var total := 0.0
	var total_r := 0.0
	var total_g := 0.0
	var total_b := 0.0
	var sq := 0.0
	var tilt := 0.0
	for y in live.get_height():
		for x in live.get_width():
			var color: Color = live.get_pixel(x, y)
			var value := (color.r + color.g + color.b) / 3.0
			total += value
			total_r += color.r
			total_g += color.g
			total_b += color.b
			sq += value * value
			tilt += sqrt((color.r - 0.5) * (color.r - 0.5) + (color.g - 0.5) * (color.g - 0.5))
	var mean := total / count
	return {
		"mean_r": total_r / count,
		"mean_g": total_g / count,
		"mean_b": total_b / count,
		"spread": sqrt(max(sq / count - mean * mean, 0.0)),
		"tilt": tilt / count,
	}


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		print("FAIL: %s" % description)
