extends Control
class_name HeightPanel
## Height From Diffuse tool panel, laid out like Materialize's window
## (`HeightFromDiffuseGui.cs` `DoMyWindow`, 300 x 590 px), top to bottom:
##
##   " Diffuse" / "Original Diffuse" / " Normal"   source radio row
##   "Height Reveal Slider"                        preview reveal (0..1, 0.5)
##   "Frequency Weight Equalizer"                  7 vertical faders, Blur6 (left)
##                                                 to Blur0 (right), 0..1, +
##                                                 "Default" "Details" "Displace"
##   "Frequency Contrast Equalizer"                7 vertical faders, -5..5, +
##                                                 "Default" "Cracks" "Funky"
##   "Color Sample 1" fold group:   header row = fold button +
##                                  "Use Color Sample 1" + "Isolate Mask";
##                                  body = "Pick Color" + swatch, then
##                                  faders Hue Sat Lum Low High Height
##   "Color Sample 2" fold group:   the same block
##   "Sample Blend"
##   "Final Gain" (-0.5..0.5) "Final Contrast" (-10..10) "Final Bias" (-1..1)
##   "Set as Height Map"
##
## The widgets are authored in `MapModules/heightMap/height_panel.tscn`; this
## script wires each one to a settings path in the shared settings Dictionary
## that `HeightFromDiffuse` reads when it generates. Every edit emits
## `settings_changed` (the shell debounces and regenerates), `preview_changed`
## for the reveal slider (preview only, no regeneration), `apply_requested` for
## "Set as Height Map", and `color_pick_requested` asks the shell to sample a
## colour from the source.
##
## Deviations from Unity: Materialize draws at absolute pixel rects inside a
## draggable window; Godot uses containers, so the groups stretch. Materialize's
## `GuiHelper.Slider` shows the value in an editable text field next to each
## horizontal slider; here every slider gets a value label, including the
## vertical faders, which have no text field in Unity.
##
## The fold groups are port-only too: Unity has no fold control, and a sample's
## swatch, "Pick Color", and faders are drawn only while `UseSample1` is on
## (`HeightFromDiffuseGui.cs` lines 714-751, 760-797). Godot stacks the groups
## in one column, so the two sample bodies are 110 px of faders each and push
## "Set as Height Map" out of the panel. Each sample is therefore a
## `CollapseGroup` (`ui/collapse_group.gd`): its header keeps the two
## checkboxes reachable while the body is folded, and `Use Color Sample N` off
## folds that sample, which is Unity's behaviour expressed as a fold.
##
## "Sample Spread" / "Sample Spread Boost" are Unity's Normal-mode sliders and
## are not drawn: the Normal source comes with Normal From Height.

signal settings_changed()
signal preview_changed()
signal apply_requested()
signal color_pick_requested(sample_index: int)

## Rows: [slider node path, settings path, value label node path, preview-only].
## The faders run coarse (Blur6, leftmost) to fine (Blur0, rightmost), exactly
## as Materialize places them.
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const SLIDER_ROWS := [
	["Column/RevealGroup/Reveal", ["reveal"], "Column/RevealGroup/RevealVal", true],

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

	["Column/Sample1Group/Body/Row/Faders/H1/Slider", ["sample1", "hue"], "Column/Sample1Group/Body/Row/Faders/H1/Val"],
	["Column/Sample1Group/Body/Row/Faders/S1/Slider", ["sample1", "sat"], "Column/Sample1Group/Body/Row/Faders/S1/Val"],
	["Column/Sample1Group/Body/Row/Faders/L1/Slider", ["sample1", "lum"], "Column/Sample1Group/Body/Row/Faders/L1/Val"],
	["Column/Sample1Group/Body/Row/Faders/ML1/Slider", ["sample1", "mask_low"], "Column/Sample1Group/Body/Row/Faders/ML1/Val"],
	["Column/Sample1Group/Body/Row/Faders/MH1/Slider", ["sample1", "mask_high"], "Column/Sample1Group/Body/Row/Faders/MH1/Val"],
	["Column/Sample1Group/Body/Row/Faders/SH1/Slider", ["sample1", "height"], "Column/Sample1Group/Body/Row/Faders/SH1/Val"],

	["Column/Sample2Group/Body/Row/Faders/H2/Slider", ["sample2", "hue"], "Column/Sample2Group/Body/Row/Faders/H2/Val"],
	["Column/Sample2Group/Body/Row/Faders/S2/Slider", ["sample2", "sat"], "Column/Sample2Group/Body/Row/Faders/S2/Val"],
	["Column/Sample2Group/Body/Row/Faders/L2/Slider", ["sample2", "lum"], "Column/Sample2Group/Body/Row/Faders/L2/Val"],
	["Column/Sample2Group/Body/Row/Faders/ML2/Slider", ["sample2", "mask_low"], "Column/Sample2Group/Body/Row/Faders/ML2/Val"],
	["Column/Sample2Group/Body/Row/Faders/MH2/Slider", ["sample2", "mask_high"], "Column/Sample2Group/Body/Row/Faders/MH2/Val"],
	["Column/Sample2Group/Body/Row/Faders/SH2/Slider", ["sample2", "height"], "Column/Sample2Group/Body/Row/Faders/SH2/Val"],

	["Column/BlendGroup/Blend", ["sample_blend"], "Column/BlendGroup/BlendVal"],

	["Column/FinalGroup/Gain", ["final_gain"], "Column/FinalGroup/GainVal"],
	["Column/FinalGroup/Contrast", ["final_contrast"], "Column/FinalGroup/ContrastVal"],
	["Column/FinalGroup/Bias", ["final_bias"], "Column/FinalGroup/BiasVal"],
]

## Rows: [checkbox node path, settings path].
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const CHECK_ROWS := [
	["Column/SourceRow/UseDiffuse", ["use_adjusted_diffuse"]],
	["Column/SourceRow/UseOriginal", ["use_original_diffuse"]],
	["Column/SourceRow/UseNormal", ["use_normal"]],
	["Column/Sample1Group/Header/Use1", ["sample1", "use"]],
	["Column/Sample1Group/Header/Isolate1", ["sample1", "isolate"]],
	["Column/Sample2Group/Header/Use2", ["sample2", "use"]],
	["Column/Sample2Group/Header/Isolate2", ["sample2", "isolate"]],
]

## sample settings key -> [fold group node path, isolate checkbox node path].
## `Use Color Sample N` drives its fold group: Unity draws a sample's swatch,
## "Pick Color", and faders only while `UseSampleN` is on, so the sample body
## folds when the box goes off, and Isolate Mask is disabled with it
## (`HeightFromDiffuseGui.cs` lines 714-751, 760-797, and `GUI.enabled` on the
## isolate toggle, line 717).
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const SAMPLE_FOLDS := {
	"sample1": ["Column/Sample1Group", "Column/Sample1Group/Header/Isolate1"],
	"sample2": ["Column/Sample2Group", "Column/Sample2Group/Header/Isolate2"],
}

## Rows: [color picker node path, settings path].
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const COLOR_ROWS := [
	["Column/Sample1Group/Body/Row/Left/Color1", ["sample1", "color"]],
	["Column/Sample2Group/Body/Row/Left/Color2", ["sample2", "color"]],
]

## Rows: [button node path, sample index].
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const PICK_ROWS := [
	["Column/Sample1Group/Body/Row/Left/Pick1", 1],
	["Column/Sample2Group/Body/Row/Left/Pick2", 2],
]

## Rows: [button node path, settings key, preset name]. Labels are Materialize's
## button strings: Default / Details / Displace and Default / Cracks / Funky.
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
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
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
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
		var slider: Slider = get_node(row[0])
		slider.value = float(_value(row[1]))
		get_node(row[2]).text = "%.2f" % slider.value
	for row: Array in CHECK_ROWS:
		(get_node(row[0]) as CheckBox).button_pressed = bool(_value(row[1]))
	for row: Array in COLOR_ROWS:
		(get_node(row[0]) as ColorPicker).color = _value(row[1])
	_sync_folds()
	_syncing = false

## The main scene picked a colour from a preview for one sample.
func set_sample_color(sample_index: int, color: Color) -> void:
	_assign(["sample%d" % sample_index, "color"], color)
	refresh()

func _ready() -> void:
	for row: Array in SLIDER_ROWS:
		(get_node(row[0]) as Slider).value_changed.connect(_on_slider_changed.bind(row))
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
	if _syncing:
		return
	# The Height Reveal Slider is preview-only, so it does not need a
	# regeneration: the shell re-blends the preview instead.
	if row.size() > 3 and row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_check_changed(toggled: bool, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], toggled)
	if row[1][0] == "use_adjusted_diffuse" or row[1][0] == "use_original_diffuse" or row[1][0] == "use_normal":
		_enforce_source_row()
	else:
		_enforce_isolate(row)
		# Unity draws a sample's body only while its Use box is on, so the fold
		# group mirrors the setting, and Isolate Mask is disabled with the sample.
		_sync_folds()
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

## Unity's isolate rules (`HeightFromDiffuseGui.cs` lines 718-721, 755, 764-767,
## 801): isolating one sample turns the other sample's isolate off, and
## switching a sample off turns its own isolate off.
func _enforce_isolate(row: Array) -> void:
	var sample := String(row[1][0])
	var isolate_key := String(row[1][1])
	if isolate_key == "use":
		if not bool(_settings[sample]["isolate"]):
			return
		_settings[sample]["isolate"] = false
		return
	if bool(_settings[sample]["isolate"]):
		var other := "sample2" if sample == "sample1" else "sample1"
		_settings[other]["isolate"] = false

## Push the sample settings into the fold groups. The body is open only while
## `Use Color Sample N` is on (Unity draws the swatch, "Pick Color", and the
## faders inside the `if (HFDS.UseSampleN)` block), so a folded body means the
## sample is off, and "Isolate Mask" is greyed out with it, the way Unity's
## `GUI.enabled` covers the isolate toggle.
func _sync_folds() -> void:
	for sample: String in SAMPLE_FOLDS:
		var use := bool(_settings[sample]["use"])
		(get_node(SAMPLE_FOLDS[sample][0]) as CollapseGroup).set_collapsed(not use)
		(get_node(SAMPLE_FOLDS[sample][1]) as CheckBox).disabled = not use

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
