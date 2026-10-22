extends VBoxContainer
## Height From Diffuse control panel.
##
## The widgets are authored in `height_panel.tscn`; this script wires each one
## to a settings path in the shared settings Dictionary that
## `HeightFromDiffuse` reads when it generates. Every edit emits
## `settings_changed`, so the main scene can regenerate. `color_pick_requested`
## asks the main scene to start sampling a colour from the source image.

signal settings_changed()
signal color_pick_requested(sample_index: int)

## Rows: [slider node path, settings path, value label node path].
const SLIDER_ROWS := [
	["Weights/W0", ["weights", 0], "Weights/W0Val"],
	["Weights/W1", ["weights", 1], "Weights/W1Val"],
	["Weights/W2", ["weights", 2], "Weights/W2Val"],
	["Weights/W3", ["weights", 3], "Weights/W3Val"],
	["Weights/W4", ["weights", 4], "Weights/W4Val"],
	["Weights/W5", ["weights", 5], "Weights/W5Val"],
	["Weights/W6", ["weights", 6], "Weights/W6Val"],

	["Contrasts/C0", ["contrasts", 0], "Contrasts/C0Val"],
	["Contrasts/C1", ["contrasts", 1], "Contrasts/C1Val"],
	["Contrasts/C2", ["contrasts", 2], "Contrasts/C2Val"],
	["Contrasts/C3", ["contrasts", 3], "Contrasts/C3Val"],
	["Contrasts/C4", ["contrasts", 4], "Contrasts/C4Val"],
	["Contrasts/C5", ["contrasts", 5], "Contrasts/C5Val"],
	["Contrasts/C6", ["contrasts", 6], "Contrasts/C6Val"],

	["OutputGrid/FC", ["final_contrast"], "OutputGrid/FCVal"],
	["OutputGrid/FB", ["final_bias"], "OutputGrid/FBVal"],
	["OutputGrid/FG", ["final_gain"], "OutputGrid/FGVal"],

	["Sample1Grid/H1", ["sample1", "hue"], "Sample1Grid/H1Val"],
	["Sample1Grid/S1", ["sample1", "sat"], "Sample1Grid/S1Val"],
	["Sample1Grid/L1", ["sample1", "lum"], "Sample1Grid/L1Val"],
	["Sample1Grid/ML1", ["sample1", "mask_low"], "Sample1Grid/ML1Val"],
	["Sample1Grid/MH1", ["sample1", "mask_high"], "Sample1Grid/MH1Val"],
	["Sample1Grid/SH1", ["sample1", "height"], "Sample1Grid/SH1Val"],

	["Sample2Grid/H2", ["sample2", "hue"], "Sample2Grid/H2Val"],
	["Sample2Grid/S2", ["sample2", "sat"], "Sample2Grid/S2Val"],
	["Sample2Grid/L2", ["sample2", "lum"], "Sample2Grid/L2Val"],
	["Sample2Grid/ML2", ["sample2", "mask_low"], "Sample2Grid/ML2Val"],
	["Sample2Grid/MH2", ["sample2", "mask_high"], "Sample2Grid/MH2Val"],
	["Sample2Grid/SH2", ["sample2", "height"], "Sample2Grid/SH2Val"],
	["Sample2Grid/BL", ["sample_blend"], "Sample2Grid/BLVal"],
]

## Rows: [checkbox node path, settings path].
const CHECK_ROWS := [
	["Sample1Top/Use1", ["sample1", "use"]],
	["Sample1Top/Isolate1", ["sample1", "isolate"]],
	["Sample2Top/Use2", ["sample2", "use"]],
	["Sample2Top/Isolate2", ["sample2", "isolate"]],
]

## Rows: [color picker node path, settings path].
const COLOR_ROWS := [
	["Sample1Top/Color1", ["sample1", "color"]],
	["Sample2Top/Color2", ["sample2", "color"]],
]

## Rows: [button node path, sample index].
const PICK_ROWS := [
	["Sample1Top/Pick1", 1],
	["Sample2Top/Pick2", 2],
]

## Rows: [button node path, settings key, preset name].
const PRESET_ROWS := [
	["Presets/WDefault", "weights", "default"],
	["Presets/WDetail", "weights", "detail"],
	["Presets/WDisplace", "weights", "displace"],
	["Presets/CDefault", "contrasts", "default"],
	["Presets/CCrackedMud", "contrasts", "cracked_mud"],
	["Presets/CFunky", "contrasts", "funky"],
]

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a HeightFromDiffuse instance. The panel
## edits it in place, so the tool always sees the current values.
func setup(settings: Dictionary) -> void:
	_settings = settings
	refresh()

## Push the settings Dictionary into the widgets.
func refresh() -> void:
	_syncing = true
	for row: Array in SLIDER_ROWS:
		var slider: HSlider = get_node(row[0])
		slider.value = float(_value(row[1]))
		get_node(row[2]).text = "%.2f" % slider.value
	for row: Array in CHECK_ROWS:
		get_node(row[0]).button_pressed = bool(_value(row[1]))
	for row: Array in COLOR_ROWS:
		get_node(row[0]).color = _value(row[1])
	_syncing = false

## The main scene picked a colour from the source image for one sample.
func set_sample_color(sample_index: int, color: Color) -> void:
	_assign(["sample%d" % sample_index, "color"], color)
	refresh()

func _ready() -> void:
	for row: Array in SLIDER_ROWS:
		get_node(row[0]).value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in CHECK_ROWS:
		get_node(row[0]).toggled.connect(_on_check_changed.bind(row))
	for row: Array in COLOR_ROWS:
		get_node(row[0]).color_changed.connect(_on_color_changed.bind(row))
	for row: Array in PICK_ROWS:
		get_node(row[0]).pressed.connect(_on_pick_pressed.bind(row))
	for row: Array in PRESET_ROWS:
		get_node(row[0]).pressed.connect(_on_preset_pressed.bind(row))

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
	if not _syncing:
		settings_changed.emit()

func _on_color_changed(color: Color, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], color)
	if not _syncing:
		settings_changed.emit()

func _on_pick_pressed(row: Array) -> void:
	color_pick_requested.emit(row[1])

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
