extends Control
class_name HeightPanel
## Height From Diffuse tool scene, laid out like Materialize's window
## (`HeightFromDiffuseGui.cs` `DoMyWindow`), top to bottom:
##
##   Diffuse / Original Diffuse / Normal    source radio row
##   Height Reveal Slider                   preview reveal
##   Frequency Weight Equalizer             7 vertical faders (coarse .. fine,
##                                          left to right, as in Materialize)
##                                          + Default / Details / Displace
##   Frequency Contrast Equalizer           7 vertical faders
##                                          + Default / Cracks / Funky
##   Use Color Sample 1 + Isolate Mask      Pick Color + swatch
##                                          + Hue Sat Lum Low High Height faders
##   Use Color Sample 2 ...                same block
##   Sample Blend
##   Final Gain (-0.5..0.5), Final Contrast (-10..10), Final Bias (-1..1)
##   Set as Height Map
##
## The widgets are authored in `scenes/tools/height_from_diffuse.tscn`; this
## script wires each one to a settings path in the shared settings Dictionary
## that `HeightFromDiffuse` reads when it generates. Every edit emits
## `settings_changed`, `Set as Height Map` emits `apply_requested`, and
## `color_pick_requested` asks the main scene to sample a colour from a preview.
##
## Deviations: Materialize draws at absolute pixel rects inside a 300x590
## draggable window; Godot uses containers, so the groups can stretch. Materialize
## shows the value of most sliders in a text field next to them
## (`GuiHelper.Slider`); here every slider gets a value label.

signal settings_changed()
signal apply_requested()
signal color_pick_requested(sample_index: int)

## Rows: [slider node path, settings path, value label node path].
## The equalizer faders run coarse (Blur6) to fine (Blur0), left to right,
## exactly as Materialize places them.
const SLIDER_ROWS := [
	["Column/RevealGroup/Reveal", ["reveal"], "Column/RevealGroup/RevealVal"],

	["Column/WeightGroup/Row/Faders/W6/Slider", ["weights", 6], "Column/WeightGroup/Row/Faders/W6/Val"],
	["Column/WeightGroup/Row/Faders/W5/Slider", ["weights", 5], "Column/WeightGroup/Row/Faders/W5/Val"],
	["Column/WeightGroup/Row/Faders/W4/Slider", ["weights", 4], "Column/WeightGroup/Row/Faders/W4/Val"],
	["Column/WeightGroup/Row/Faders/W3/Slider", ["weights", 3], "Column/WeightGroup/Row/Faders/W3/Val"],
	["Column/WeightGroup/Row/Faders/W2/Slider", ["weights", 2], "Column/WeightGroup/Row/Faders/W2/Val"],
	["Column/WeightGroup/Row/Faders/W1/Slider", ["weights", 1], "Column/WeightGroup/Row/Faders/W1/Val"],
	["Column/WeightGroup/Row/Faders/W0/Slider", ["weights", 0], "Column/WeightGroup/Row/Faders/W0/Val"],

	["Column/ContrastGroup/Row/Faders/C6/Slider", ["contrasts", 6], "Column/ContrastGroup/Row/Faders/C6/Val"],
	["Column/ContrastGroup/Row/Faders/C5/Slider", ["contrasts", 5], "Column/ContrastGroup/Row/Faders/C5/Val"],
	["Column/ContrastGroup/Row/Faders/C4/Slider", ["contrasts", 4], "Column/ContrastGroup/Row/Faders/C4/Val"],
	["Column/ContrastGroup/Row/Faders/C3/Slider", ["contrasts", 3], "Column/ContrastGroup/Row/Faders/C3/Val"],
	["Column/ContrastGroup/Row/Faders/C2/Slider", ["contrasts", 2], "Column/ContrastGroup/Row/Faders/C2/Val"],
	["Column/ContrastGroup/Row/Faders/C1/Slider", ["contrasts", 1], "Column/ContrastGroup/Row/Faders/C1/Val"],
	["Column/ContrastGroup/Row/Faders/C0/Slider", ["contrasts", 0], "Column/ContrastGroup/Row/Faders/C0/Val"],

	["Column/Sample1Group/Row/Faders/H1/Slider", ["sample1", "hue"], "Column/Sample1Group/Row/Faders/H1/Val"],
	["Column/Sample1Group/Row/Faders/S1/Slider", ["sample1", "sat"], "Column/Sample1Group/Row/Faders/S1/Val"],
	["Column/Sample1Group/Row/Faders/L1/Slider", ["sample1", "lum"], "Column/Sample1Group/Row/Faders/L1/Val"],
	["Column/Sample1Group/Row/Faders/ML1/Slider", ["sample1", "mask_low"], "Column/Sample1Group/Row/Faders/ML1/Val"],
	["Column/Sample1Group/Row/Faders/MH1/Slider", ["sample1", "mask_high"], "Column/Sample1Group/Row/Faders/MH1/Val"],
	["Column/Sample1Group/Row/Faders/SH1/Slider", ["sample1", "height"], "Column/Sample1Group/Row/Faders/SH1/Val"],

	["Column/Sample2Group/Row/Faders/H2/Slider", ["sample2", "hue"], "Column/Sample2Group/Row/Faders/H2/Val"],
	["Column/Sample2Group/Row/Faders/S2/Slider", ["sample2", "sat"], "Column/Sample2Group/Row/Faders/S2/Val"],
	["Column/Sample2Group/Row/Faders/L2/Slider", ["sample2", "lum"], "Column/Sample2Group/Row/Faders/L2/Val"],
	["Column/Sample2Group/Row/Faders/ML2/Slider", ["sample2", "mask_low"], "Column/Sample2Group/Row/Faders/ML2/Val"],
	["Column/Sample2Group/Row/Faders/MH2/Slider", ["sample2", "mask_high"], "Column/Sample2Group/Row/Faders/MH2/Val"],
	["Column/Sample2Group/Row/Faders/SH2/Slider", ["sample2", "height"], "Column/Sample2Group/Row/Faders/SH2/Val"],

	["Column/BlendGroup/Blend", ["sample_blend"], "Column/BlendGroup/BlendVal"],

	["Column/FinalGroup/Gain", ["final_gain"], "Column/FinalGroup/GainVal"],
	["Column/FinalGroup/Contrast", ["final_contrast"], "Column/FinalGroup/ContrastVal"],
	["Column/FinalGroup/Bias", ["final_bias"], "Column/FinalGroup/BiasVal"],
]

## Rows: [checkbox node path, settings path].
const CHECK_ROWS := [
	["Column/SourceRow/UseDiffuse", ["use_adjusted_diffuse"]],
	["Column/SourceRow/UseOriginal", ["use_original_diffuse"]],
	["Column/SourceRow/UseNormal", ["use_normal"]],
	["Column/Sample1Group/Top/Use1", ["sample1", "use"]],
	["Column/Sample1Group/Top/Isolate1", ["sample1", "isolate"]],
	["Column/Sample2Group/Top/Use2", ["sample2", "use"]],
	["Column/Sample2Group/Top/Isolate2", ["sample2", "isolate"]],
]

## Rows: [color picker node path, settings path].
const COLOR_ROWS := [
	["Column/Sample1Group/Row/Left/Color1", ["sample1", "color"]],
	["Column/Sample2Group/Row/Left/Color2", ["sample2", "color"]],
]

## Rows: [button node path, sample index].
const PICK_ROWS := [
	["Column/Sample1Group/Row/Left/Pick1", 1],
	["Column/Sample2Group/Row/Left/Pick2", 2],
]

## Rows: [button node path, settings key, preset name].
const PRESET_ROWS := [
	["Column/WeightGroup/Row/Presets/Default", "weights", "default"],
	["Column/WeightGroup/Row/Presets/Details", "weights", "detail"],
	["Column/WeightGroup/Row/Presets/Displace", "weights", "displace"],
	["Column/ContrastGroup/Row/Presets/Default", "contrasts", "default"],
	["Column/ContrastGroup/Row/Presets/Cracks", "contrasts", "cracked_mud"],
	["Column/ContrastGroup/Row/Presets/Funky", "contrasts", "funky"],
]

## The source checkboxes that are not implemented yet stay disabled: the port
## reads the loaded diffuse, and "Original Diffuse" / " Normal" need the
## original image and a normal map source, which come with later tools.
const DISABLED_SOURCE_CHECKS := ["Column/SourceRow/UseOriginal", "Column/SourceRow/UseNormal"]

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a HeightFromDiffuse instance. The panel
## edits it in place, so the tool always sees the current values.
func setup(settings: Dictionary) -> void:
	_settings = settings
	for path: String in DISABLED_SOURCE_CHECKS:
		(get_node(path) as CheckBox).disabled = true
	refresh()

## Push the settings Dictionary into the widgets.
func refresh() -> void:
	_syncing = true
	for row: Array in SLIDER_ROWS:
		var slider: HSlider = get_node(row[0])
		slider.value = float(_value(row[1]))
		get_node(row[2]).text = "%.2f" % slider.value
	for row: Array in CHECK_ROWS:
		(get_node(row[0]) as CheckBox).button_pressed = bool(_value(row[1]))
	for row: Array in COLOR_ROWS:
		(get_node(row[0]) as ColorPicker).color = _value(row[1])
	_syncing = false

## The main scene picked a colour from a preview for one sample.
func set_sample_color(sample_index: int, color: Color) -> void:
	_assign(["sample%d" % sample_index, "color"], color)
	refresh()

func _ready() -> void:
	for row: Array in SLIDER_ROWS:
		(get_node(row[0]) as HSlider).value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in CHECK_ROWS:
		(get_node(row[0]) as CheckBox).toggled.connect(_on_check_changed.bind(row))
	for row: Array in COLOR_ROWS:
		(get_node(row[0]) as ColorPicker).color_changed.connect(_on_color_changed.bind(row))
	for row: Array in PICK_ROWS:
		(get_node(row[0]) as Button).pressed.connect(_on_pick_pressed.bind(row))
	for row: Array in PRESET_ROWS:
		(get_node(row[0]) as Button).pressed.connect(_on_preset_pressed.bind(row))
	($Column/SetButton as Button).pressed.connect(_on_set_pressed)

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], value)
	get_node(row[2]).text = "%.2f" % value
	if not _syncing:
		settings_changed.emit()

func _on_check_changed(toggled: bool, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], toggled)
	if row[1][0] == "use_adjusted_diffuse" or row[1][0] == "use_original_diffuse" or row[1][0] == "use_normal":
		_enforce_source_row()
	if not _syncing:
		settings_changed.emit()

## Materialize's source row is a radio group: turning one source on turns the
## others off, and if all three go off the first one is forced back on.
func _enforce_source_row() -> void:
	var diffuse: bool = bool(_settings["use_adjusted_diffuse"])
	var original: bool = bool(_settings["use_original_diffuse"])
	var normal: bool = bool(_settings["use_normal"])
	if diffuse:
		original = false
		normal = false
	elif original:
		diffuse = false
		normal = false
	elif normal:
		diffuse = false
		original = false
	else:
		diffuse = true
		original = false
		normal = false
	_settings["use_adjusted_diffuse"] = diffuse
	_settings["use_original_diffuse"] = original
	_settings["use_normal"] = normal
	_syncing = true
	refresh()
	_syncing = false

func _on_color_changed(color: Color, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], color)
	if not _syncing:
		settings_changed.emit()

func _on_pick_pressed(row: Array) -> void:
	color_pick_requested.emit(row[1])

func _on_set_pressed() -> void:
	if _settings.is_empty():
		return
	apply_requested.emit()

func _on_preset_pressed(row: Array) -> void:
	if _settings.is_empty():
		return
	var table: Dictionary = HeightFromDiffuse.PRESET_WEIGHTS
	if row[1] == "contrasts":
		table = HeightFromDiffuse.PRESET_CONTRASTS
	_settings[row[1]] = (table[row[2]] as Array).duplicate()
	refresh()
	if not _syncing:
		settings_changed.emit()

## Reads a nested settings value, e.g. ["sample1", "hue"] or ["weights", 3].
## The node is Variant, not Dictionary, because a settings path can end at an
## Array element (weights / contrasts), which is not a Dictionary.
func _value(target: Array) -> Variant:
	var node: Variant = _settings
	for key in target.slice(0, -1):
		node = node[key]
	return node[target[-1]]

func _assign(target: Array, value: Variant) -> void:
	var node: Variant = _settings
	for key in target.slice(0, -1):
		node = node[key]
	node[target[-1]] = value
