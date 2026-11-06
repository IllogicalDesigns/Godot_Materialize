extends SceneTree
## Reset-button check: every map panel owns a "Reset Parameters" button, and
## pressing it restores the module's settings Dictionary to defaults, refreshes
## the widgets, and asks the shell to regenerate. One-off probe, run with
## `godot --headless -s tests/reset_check.gd`; the GPU passes need a real
## window, so this probe drives the panel-module contract only, the same way
## `main.gd` `_on_reset_requested` drives it in the app.
##
## Each case: [map_type, panel scene, slider export, settings key, test value].
## The slider is edited through the widget, the way the user edits it, so the
## reset has something to undo. One case runs per frame, so `_ready` wires the
## panel's signals before the press.

const CASES := [
	["height", "res://MapModules/heightMap/height_panel.tscn", "gain_slider", "final_gain", 0.4],
	["diffuse", "res://MapModules/diffuseMap/diffuse_panel.tscn", "light_power_slider", "light_mask_power", 0.9],
	["normal", "res://MapModules/normalMap/normal_panel.tscn", "shape_bias_slider", "shape_bias", 0.8],
	["metallic", "res://MapModules/metallicMap/metallic_panel.tscn", "blur_size_slider", "blur_size", 55.0],
	["roughness", "res://MapModules/roughnessMap/roughness_panel.tscn", "base_roughness_slider", "base_roughness", 0.2],
	["ao", "res://MapModules/aoMap/ao_panel.tscn", "spread_slider", "spread", 90.0],
]

var _index := 0
var _panel: Control
var _module: MapModule

func _process(_delta: float) -> bool:
	if _index >= CASES.size():
		_extra()
		print("[reset_check] PASS: all 6 panels reset to defaults")
		return true
	var case: Array = CASES[_index]
	var map_type: String = case[0]
	_module = _make_module(map_type)
	root.add_child(_module)
	_panel = (load(case[1]) as PackedScene).instantiate()
	root.add_child(_panel)
	_panel.setup(_module.settings())
	# The shell's contract: the panel emits `reset_requested`, the shell resets
	# the Dictionary in place and refreshes, verbatim from `main.gd`.
	_panel.connect("reset_requested", _on_reset)

	var slider: Slider = _panel.get(case[2])
	var key: String = case[3]
	var test: float = float(case[4])
	var default: float = float(_module.default_settings()[key])
	if is_equal_approx(test, default):
		_fail(map_type, "the test value is the default value")
		return true
	if not is_equal_approx(slider.value, default):
		_fail(map_type, "the panel did not start at defaults")
		return true
	slider.value = test
	if not is_equal_approx(float(_module.settings()[key]), test):
		_fail(map_type, "the slider did not write the settings Dictionary")
		return true
	_panel.reset_button.pressed.emit()
	if not is_equal_approx(float(_module.settings()[key]), default):
		_fail(map_type, "settings not restored for %s" % key)
		return true
	if not is_equal_approx(slider.value, default):
		_fail(map_type, "slider not refreshed for %s" % key)
		return true
	# The reset must be in place: the panel keeps the Dictionary it edits.
	if not (_panel.get("_settings") == _module.settings()):
		_fail(map_type, "reset replaced the settings Dictionary")
		return true
	print("[reset_check] %s: %s %.2f -> %.2f, widget refreshed" % [map_type, key, test, default])
	_index += 1
	return false

## The Height panel also stores nested sample blocks and the weight fader
## Array, so the reset check covers a sample swatch, a sample level, and a
## weight fader as well.
func _extra() -> void:
	_module = HeightMapModule.new()
	root.add_child(_module)
	_panel = (load("res://MapModules/heightMap/height_panel.tscn") as PackedScene).instantiate()
	root.add_child(_panel)
	_panel.setup(_module.settings())
	_panel.connect("reset_requested", _on_reset)
	_panel.use1_check.button_pressed = true
	# A picked swatch and a raised sample level, keys inside the sample1
	# Dictionary, plus one weight fader: the settings Array index is the
	# reversed scene position.
	_panel.set_sample_color(1, Color(0.9, 0.1, 0.1, 1.0))
	_panel.sample1_faders[5].slider.value = 0.9
	_panel.weight_faders[0].slider.value = 0.6
	_panel.reset_button.pressed.emit()
	var sample: Dictionary = _module.settings()["sample1"]
	var weights: Array = _module.settings()["weights"]
	var fresh: Dictionary = _module.default_settings()
	if not (sample["color"] == fresh["sample1"]["color"]
			and is_equal_approx(float(sample["height"]), float(fresh["sample1"]["height"]))
			and is_equal_approx(float(weights[weights.size() - 1]), float(fresh["weights"][weights.size() - 1]))):
		_fail("height", "nested settings not restored")
		return
	if not is_equal_approx(_panel.sample1_faders[5].slider.value, float(fresh["sample1"]["height"])):
		_fail("height", "sample fader not refreshed")
		return
	print("[reset_check] height: sample swatch, sample level, and weight fader all restored")

func _fail(map_type: String, text: String) -> void:
	print("[reset_check] %s FAIL: %s" % [map_type, text])
	quit(1)

func _on_reset() -> void:
	_module.reset_settings()
	_panel.call("refresh")

func _make_module(map_type: String) -> MapModule:
	match map_type:
		"height":
			return HeightMapModule.new()
		"diffuse":
			return DiffuseMapModule.new()
		"normal":
			return NormalMapModule.new()
		"metallic":
			return MetallicMapModule.new()
		"roughness":
			return RoughnessMapModule.new()
		"ao":
			return AOMapModule.new()
	return null
