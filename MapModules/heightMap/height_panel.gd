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
## The widgets are authored in `MapModules/heightMap/height_panel.tscn`; every
## widget this script wires is an `@export` assigned in the Inspector, so the
## script holds no node paths (`CODING_RULES.md`). Each export is bound to a
## settings path in the shared settings Dictionary that `HeightFromDiffuse`
## reads when it generates. Every edit emits `settings_changed` (the shell
## debounces and regenerates), `preview_changed` for the reveal slider (preview
## only, no regeneration), `apply_requested` for "Set as Height Map", and
## `color_pick_requested` asks the shell to sample a colour from the source.
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
## the window taller than Unity's 590 px.

signal settings_changed()
signal preview_changed()
signal apply_requested()
signal color_pick_requested(sample_index: int)

## The Reveal pair: the preview slider and its value label.
@export var reveal_slider: Slider
@export var reveal_label: Label

## The three fader groups, in scene order. Weight faders run coarse (Blur6,
## leftmost) to fine (Blur0, rightmost), exactly as Materialize places them;
## the settings key is `weights` / `contrasts` indexed by the reversed position.
@export var weight_faders: Array[FaderGroup]
@export var contrast_faders: Array[FaderGroup]
@export var sample1_faders: Array[FaderGroup]
@export var sample2_faders: Array[FaderGroup]

## The preset buttons, in Unity's row order.
@export var weight_default_button: Button
@export var weight_details_button: Button
@export var weight_displace_button: Button
@export var contrast_default_button: Button
@export var contrast_cracks_button: Button
@export var contrast_funky_button: Button

## The single slider pairs: Blend, Final Gain, Final Contrast, Final Bias.
@export var blend_slider: Slider
@export var blend_label: Label
@export var gain_slider: Slider
@export var gain_label: Label
@export var final_contrast_slider: Slider
@export var final_contrast_label: Label
@export var final_bias_slider: Slider
@export var final_bias_label: Label

## The source radio row.
@export var use_diffuse_check: CheckBox
@export var use_original_check: CheckBox
@export var use_normal_check: CheckBox

## The sample header checkboxes.
@export var use1_check: CheckBox
@export var isolate1_check: CheckBox
@export var use2_check: CheckBox
@export var isolate2_check: CheckBox

## The sample colour swatches and "Pick Color" buttons.
@export var color1_picker: ColorPicker
@export var color2_picker: ColorPicker
@export var pick1_button: Button
@export var pick2_button: Button

## The sample fold groups.
@export var sample1_fold: CollapseGroup
@export var sample2_fold: CollapseGroup

## "Set as Height Map".
@export var set_button: Button

## The fader keys, in the order Materialize draws them inside a sample.
const SAMPLE_KEYS := ["hue", "sat", "lum", "mask_low", "mask_high", "height"]

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a HeightFromDiffuse instance. The panel
## edits it in place, so the tool always sees the current values.
func setup(settings: Dictionary) -> void:
	_settings = settings
	# The port reads the loaded diffuse; "Original Diffuse" and " Normal" need
	# the original image and a normal map source, which come with later tools.
	use_original_check.disabled = true
	use_normal_check.disabled = true
	refresh()

## Push the settings Dictionary into the widgets. Both row kinds have the shape
## [widget, value label, settings path], so one loop covers sliders and faders.
func refresh() -> void:
	_syncing = true
	for row: Array in _fader_rows() + _slider_rows():
		var value := float(_value(row[2]))
		if row[0] is Slider:
			row[0].value = value
		else:
			row[0].slider.value = value
		row[1].text = "%.2f" % value
	for row: Array in _check_rows():
		row[0].button_pressed = bool(_value(row[1]))
	for row: Array in _color_rows():
		row[0].color = _value(row[1])
	_sync_folds()
	_syncing = false

## The main scene picked a colour from a preview for one sample.
func set_sample_color(sample_index: int, color: Color) -> void:
	_assign(["sample%d" % sample_index, "color"], color)
	refresh()

func _ready() -> void:
	_check_exports()
	for row: Array in _fader_rows():
		row[0].slider.value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in _slider_rows():
		row[0].value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in _check_rows():
		row[0].toggled.connect(_on_check_changed.bind(row))
	for row: Array in _color_rows():
		row[0].color_changed.connect(_on_color_changed.bind(row))
	for row: Array in _pick_rows():
		row[0].pressed.connect(_on_pick_pressed.bind(row))
	for row: Array in _preset_rows():
		row[0].pressed.connect(_on_preset_pressed.bind(row))
	set_button.pressed.connect(_on_set_pressed)

## Rows: [fader group, value label, settings path], built from the exports. The
## weight and contrast faders store the coarse-to-fine scene order in the
## settings Array, so the settings index is the reversed position. Rows share
## the shape of `_slider_rows`, so the handlers read `row[2]` for the settings
## key and `row[1]` for the value label.
func _fader_rows() -> Array:
	var rows: Array = []
	for i in weight_faders.size():
		var group: FaderGroup = weight_faders[i]
		rows.append([group, group.value_label, ["weights", weight_faders.size() - 1 - i]])
	for i in contrast_faders.size():
		var group: FaderGroup = contrast_faders[i]
		rows.append([group, group.value_label, ["contrasts", contrast_faders.size() - 1 - i]])
	for i in sample1_faders.size():
		var group: FaderGroup = sample1_faders[i]
		rows.append([group, group.value_label, ["sample1", SAMPLE_KEYS[i]]])
	for i in sample2_faders.size():
		var group: FaderGroup = sample2_faders[i]
		rows.append([group, group.value_label, ["sample2", SAMPLE_KEYS[i]]])
	return rows

## Rows: [slider, value label, settings path, preview-only], built from the
## exports, in Materialize's window order.
func _slider_rows() -> Array:
	return [
		[reveal_slider, reveal_label, ["reveal"], true],
		[blend_slider, blend_label, ["sample_blend"]],
		[gain_slider, gain_label, ["final_gain"]],
		[final_contrast_slider, final_contrast_label, ["final_contrast"]],
		[final_bias_slider, final_bias_label, ["final_bias"]],
	]

## Rows: [checkbox, settings path].
func _check_rows() -> Array:
	return [
		[use_diffuse_check, ["use_adjusted_diffuse"]],
		[use_original_check, ["use_original_diffuse"]],
		[use_normal_check, ["use_normal"]],
		[use1_check, ["sample1", "use"]],
		[isolate1_check, ["sample1", "isolate"]],
		[use2_check, ["sample2", "use"]],
		[isolate2_check, ["sample2", "isolate"]],
	]

## Rows: [color picker, settings path].
func _color_rows() -> Array:
	return [
		[color1_picker, ["sample1", "color"]],
		[color2_picker, ["sample2", "color"]],
	]

## Rows: [button, sample index].
func _pick_rows() -> Array:
	return [
		[pick1_button, 1],
		[pick2_button, 2],
	]

## Rows: [button, settings key, preset name]. Labels are Materialize's
## button strings: Default / Details / Displace and Default / Cracks / Funky.
func _preset_rows() -> Array:
	return [
		[weight_default_button, "weights", "default"],
		[weight_details_button, "weights", "detail"],
		[weight_displace_button, "weights", "displace"],
		[contrast_default_button, "contrasts", "default"],
		[contrast_cracks_button, "contrasts", "cracked_mud"],
		[contrast_funky_button, "contrasts", "funky"],
	]

## sample settings key -> [fold group, isolate checkbox]. `Use Color Sample N`
## drives its fold group: Unity draws a sample's swatch, "Pick Color", and
## faders only while `UseSampleN` is on, so the sample body folds when the box
## goes off, and Isolate Mask is disabled with it (`HeightFromDiffuseGui.cs`
## lines 714-751, 760-797, and `GUI.enabled` on the isolate toggle, line 717).
func _sample_folds() -> Array:
	return [
		["sample1", sample1_fold, isolate1_check],
		["sample2", sample2_fold, isolate2_check],
	]

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	# Every row is [widget, value label, settings path, preview-only], so the
	# settings key is row[2] and the label is row[1].
	_assign(row[2], value)
	if row[0] is Slider:
		row[0].value = value
	else:
		row[0].slider.value = value
	row[1].text = "%.2f" % value
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
	for fold: Array in _sample_folds():
		var use := bool(_settings[fold[0]]["use"])
		fold[1].set_collapsed(not use)
		fold[2].disabled = not use

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

## Reports exports that were never assigned in the Inspector, so a missing
## widget shows up as an error at load instead of a null crash mid-edit.
func _check_exports() -> void:
	for row: Array in _fader_rows():
		if row[0] == null:
			push_error("HeightPanel fader %s is not assigned in the Inspector" % row[2])
	for row: Array in _slider_rows():
		if row[0] == null:
			push_error("HeightPanel slider %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("HeightPanel value label %s is not assigned in the Inspector" % row[2])
	for row: Array in _check_rows():
		if row[0] == null:
			push_error("HeightPanel checkbox %s is not assigned in the Inspector" % row[1])
	for row: Array in _color_rows():
		if row[0] == null:
			push_error("HeightPanel colour picker %s is not assigned in the Inspector" % row[1])
	for row: Array in _pick_rows():
		if row[0] == null:
			push_error("HeightPanel pick button %s is not assigned in the Inspector" % row[0])
	for row: Array in _preset_rows():
		if row[0] == null:
			push_error("HeightPanel preset button %s is not assigned in the Inspector" % row[0])
	for fold: Array in _sample_folds():
		if fold[1] == null:
			push_error("HeightPanel fold group %s is not assigned in the Inspector" % fold[0])
	if set_button == null:
		push_error("HeightPanel has no Set button assigned in the Inspector")
