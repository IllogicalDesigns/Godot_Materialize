extends Control
class_name RoughnessPanel
## Roughness map options panel, laid out like Materialize's Smoothness window
## (`SmoothnessGui.cs` `DoMyWindow`, 300 x 490 px), top to bottom:
##
##   " Use Edited Diffuse" / " Use Original Diffuse"   source radio row
##   "Roughness Reveal Slider"                        preview reveal (0..1, 0.5)
##   "Metal Roughness"                                0..1, 0.3
##   "Color Sample 1" fold group:   header row = fold button +
##                                  "Use Color Sample 1" + "Isolate Mask";
##                                  body = "Pick Color" + swatch, then
##                                  faders Hue Sat Lum Low High Rough
##   "Color Sample 2" fold group:   the same block
##   "Base Roughness"                                 0..1, 0.9
##   "Sample Blur Size"                              0..100, 0
##   "High Pass Blur Size"                           10..100, 30
##   "High Pass Overlay"                             -10..10, 3
##   "Final Contrast"                                -2..2, 1
##   "Final Bias"                                    -0.5..0.5, 0
##   "Reset Parameters"                              restore every setting
##   "Set as Roughness"
##
## The widgets are authored in `MapModules/roughnessMap/roughness_panel.tscn`;
## every widget this script wires is an `@export` assigned in the Inspector, so
## the script holds no node paths (`CODING_RULES.md`). Each export is bound to a
## settings path in the shared settings Dictionary that `RoughnessFromDiffuse`
## reads when it generates. Every edit emits `settings_changed` (the shell
## debounces and regenerates), `preview_changed` for the reveal slider (preview
## only, no regeneration), `apply_requested` for "Set as Roughness", and
## `color_pick_requested` asks the shell to sample a colour from the source.
##
## Every level here is roughness, so "Metal Roughness", "Base Roughness", and
## the sample "Rough" faders are Unity's smoothness values inverted: 0.0 is a
## mirror, 1.0 is fully rough, which is what
## `StandardMaterial3D.roughness_texture` samples.
##
## Deviations from Unity: Materialize draws at absolute pixel rects inside a
## draggable window; Godot uses containers, so the groups stretch. Materialize's
## `GuiHelper.Slider` shows the value in an editable text field next to each
## horizontal slider; here every slider gets a value label, including the
## vertical faders, which have no text field in Unity. The swatch is a
## `ColorPicker`, which also lets the user type a colour, while Unity draws an
## 60 x 60 texture of the picked colour and offers only the mesh raycast. Unity
## ships a third colour sample; the blit pass reads only samples 1 and 2
## (`Blit_Smoothness.shader` lines 98-135), so the port has two, with no dead
## controls. Unity greys " Use Edited Diffuse" out when no edited diffuse
## exists; the port's Diffuse box always holds the loaded image, so `setup`
## keeps both boxes live.
##
## The fold groups are port-only too: Unity has no fold control, and a sample's
## swatch, "Pick Color", and faders are drawn only while `UseSample1` is on
## (`SmoothnessGui.cs` lines 479-517, 521-559). Godot stacks the groups in one
## column, so the two sample bodies are 110 px of faders each and push the
## window taller than Unity's 490 px.

signal settings_changed()
signal preview_changed()
signal apply_requested()
## "Reset Parameters" asks the shell to restore this map's settings Dictionary
## to its defaults. The panel owns no settings knowledge here: the shell resets
## the Dictionary, refreshes the widgets, and regenerates.
signal reset_requested()
## The shell samples a colour from the Diffuse preview and writes it back with
## `set_sample_color`, the same flow the Height panel's colour samples use.
signal color_pick_requested(sample_index: int)

## The Reveal pair: the preview slider and its value label.
@export var reveal_slider: Slider
@export var reveal_label: Label

## The source radio row.
@export var use_edited_check: CheckBox
@export var use_original_check: CheckBox

## "Metal Roughness" and "Base Roughness".
@export var metal_roughness_slider: Slider
@export var metal_roughness_label: Label
@export var base_roughness_slider: Slider
@export var base_roughness_label: Label

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

## The sample fader groups, in Unity's fader order: Hue, Sat, Lum, Low, High,
## Rough. The settings key comes from the row's position.
@export var sample1_faders: Array[FaderGroup]
@export var sample2_faders: Array[FaderGroup]

## The sample fold groups.
@export var sample1_fold: CollapseGroup
@export var sample2_fold: CollapseGroup

## The single slider pairs, in Materialize's window order.
@export var blur_size_slider: Slider
@export var blur_size_label: Label
@export var overlay_blur_slider: Slider
@export var overlay_blur_label: Label
@export var high_pass_slider: Slider
@export var high_pass_label: Label
@export var final_contrast_slider: Slider
@export var final_contrast_label: Label
@export var final_bias_slider: Slider
@export var final_bias_label: Label

## "Set as Roughness".
@export var set_button: Button

## "Reset Parameters", the row above the Set button.
@export var reset_button: Button

## The fader keys, in the order Materialize draws them inside a sample
## (`SmoothnessGui.cs` lines 495-511, 537-553): Hue, Sat, Lum, Low, High,
## Smooth. The last one is the sample's roughness level.
const SAMPLE1_KEYS := ["hue_weight1", "sat_weight1", "lum_weight1",
	"mask_low1", "mask_high1", "sample1_roughness"]
const SAMPLE2_KEYS := ["hue_weight2", "sat_weight2", "lum_weight2",
	"mask_low2", "mask_high2", "sample2_roughness"]

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a RoughnessFromDiffuse instance. The panel
## edits it in place, so the tool always sees the current values.
## has_edited: whether the shell has an edited diffuse for " Use Edited
## Diffuse"; Unity greys the box out without one, and forces the pristine
## source on (`SmoothnessGui.cs` lines 648-659).
func setup(settings: Dictionary, has_edited: bool = true) -> void:
	_settings = settings
	use_edited_check.disabled = not has_edited
	if not has_edited:
		_settings["use_adjusted_diffuse"] = false
		_settings["use_original_diffuse"] = true
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

## The main scene picked a colour from the Diffuse preview for one sample.
func set_sample_color(sample_index: int, color: Color) -> void:
	_assign(["sample_color%d" % sample_index], color)
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
	set_button.pressed.connect(_on_set_pressed)
	reset_button.pressed.connect(_on_reset_pressed)

## Rows: [fader group, value label, settings path], built from the exports.
## Unity draws the six faders in one row next to the swatch, in Hue / Sat / Lum
## / Low / High / Smooth order, and each writes one settings key, so the settings
## index is the scene position. Rows share the shape of `_slider_rows`, so the
## handlers read `row[2]` for the settings key and `row[1]` for the value label.
func _fader_rows() -> Array:
	var rows: Array = []
	for i in sample1_faders.size():
		var group: FaderGroup = sample1_faders[i]
		rows.append([group, group.value_label, [SAMPLE1_KEYS[i]]])
	for i in sample2_faders.size():
		var group: FaderGroup = sample2_faders[i]
		rows.append([group, group.value_label, [SAMPLE2_KEYS[i]]])
	return rows

## Rows: [slider, value label, settings path, preview-only], built from the
## exports, in Materialize's window order.
func _slider_rows() -> Array:
	return [
		[reveal_slider, reveal_label, ["reveal"], true],
		[metal_roughness_slider, metal_roughness_label, ["metal_roughness"]],
		[base_roughness_slider, base_roughness_label, ["base_roughness"]],
		[blur_size_slider, blur_size_label, ["blur_size"]],
		[overlay_blur_slider, overlay_blur_label, ["overlay_blur_size"]],
		[high_pass_slider, high_pass_label, ["blur_overlay"]],
		[final_contrast_slider, final_contrast_label, ["final_contrast"]],
		[final_bias_slider, final_bias_label, ["final_bias"]],
	]

## Rows: [checkbox, settings path].
func _check_rows() -> Array:
	return [
		[use_edited_check, ["use_adjusted_diffuse"]],
		[use_original_check, ["use_original_diffuse"]],
		[use1_check, ["use_sample1"]],
		[isolate1_check, ["isolate_sample1"]],
		[use2_check, ["use_sample2"]],
		[isolate2_check, ["isolate_sample2"]],
	]

## Rows: [color picker, settings path].
func _color_rows() -> Array:
	return [
		[color1_picker, ["sample_color1"]],
		[color2_picker, ["sample_color2"]],
	]

## Rows: [button, sample index].
func _pick_rows() -> Array:
	return [
		[pick1_button, 1],
		[pick2_button, 2],
	]

## sample settings key -> [fold group, isolate checkbox]. `Use Color Sample N`
## drives its fold group: Unity draws a sample's swatch, "Pick Color", and
## faders only while `UseSampleN` is on, so the sample body folds when the box
## goes off, and Isolate Mask is disabled with it (`SmoothnessGui.cs` lines
## 479-517, 521-559).
func _sample_folds() -> Array:
	return [
		["use_sample1", "isolate_sample1", sample1_fold, isolate1_check],
		["use_sample2", "isolate_sample2", sample2_fold, isolate2_check],
	]

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[2], value)
	if row[0] is Slider:
		row[0].value = value
	else:
		row[0].slider.value = value
	row[1].text = "%.2f" % value
	if _syncing:
		return
	# The Roughness Reveal Slider is preview-only, so it does not need a
	# regeneration: the shell moves the seam on the mesh preview instead.
	if row.size() > 3 and row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_check_changed(toggled: bool, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], toggled)
	if row[1][0] == "use_adjusted_diffuse" or row[1][0] == "use_original_diffuse":
		_enforce_source_row()
	else:
		_enforce_isolate(row)
		# Unity draws a sample's body only while its Use box is on, so the fold
		# group mirrors the setting, and Isolate Mask is disabled with the sample.
		_sync_folds()
	if not _syncing:
		settings_changed.emit()

## Materialize's source row is a radio pair: `GUI.Toggle` on " Use Edited
## Diffuse" turns " Use Original Diffuse" off, and vice versa
## (`SmoothnessGui.cs` lines 459-467), so at least one source is always on. If
## both go off, Unity's default source, the pristine image, is forced back on.
func _enforce_source_row() -> void:
	var edited: bool = bool(_settings["use_adjusted_diffuse"])
	var original: bool = bool(_settings["use_original_diffuse"])
	if edited:
		original = false
	elif original:
		edited = false
	else:
		original = true
	_settings["use_adjusted_diffuse"] = edited
	_settings["use_original_diffuse"] = original
	_syncing = true
	refresh()
	_syncing = false

## Unity's isolate rules (`SmoothnessGui.cs` lines 482-485, 516, 524-527, 558):
## isolating one sample turns the other sample's isolate off, and switching a
## sample off turns its own isolate off.
func _enforce_isolate(row: Array) -> void:
	var key := String(row[1][0])
	if key == "use_sample1":
		if bool(_settings["isolate_sample1"]):
			_settings["isolate_sample1"] = false
		_settings["isolate_sample2"] = false
	elif key == "use_sample2":
		if bool(_settings["isolate_sample2"]):
			_settings["isolate_sample2"] = false
		_settings["isolate_sample1"] = false
	elif key == "isolate_sample1" and bool(_settings["isolate_sample1"]):
		_settings["isolate_sample2"] = false
	elif key == "isolate_sample2" and bool(_settings["isolate_sample2"]):
		_settings["isolate_sample1"] = false

## Push the sample settings into the fold groups. The body is open only while
## `Use Color Sample N` is on (Unity draws the swatch, "Pick Color", and the
## faders inside the `if (SS.UseSampleN)` block), so a folded body means the
## sample is off, and "Isolate Mask" is greyed out with it, the way Unity's
## `GUI.enabled` covers the sample body.
func _sync_folds() -> void:
	for fold: Array in _sample_folds():
		var use := bool(_settings[fold[0]])
		fold[2].set_collapsed(not use)
		fold[3].disabled = not use

func _on_color_changed(color: Color, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], color)
	if not _syncing:
		settings_changed.emit()

func _on_pick_pressed(row: Array) -> void:
	# Unity's "Pick Color" arms a mesh raycast; the port asks the shell for the
	# colour under the next click on the Diffuse box preview, the same sample
	# slots the Height panel uses.
	color_pick_requested.emit(row[1])

func _on_set_pressed() -> void:
	if _settings.is_empty():
		return
	apply_requested.emit()

func _on_reset_pressed() -> void:
	if _settings.is_empty():
		return
	reset_requested.emit()

## Reads a settings value at a path, e.g. ["sample_color1"] or ["mask_low1"].
## The node is Variant, not Dictionary, because a settings path can end at an
## Array element.
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
			push_error("RoughnessPanel fader %s is not assigned in the Inspector" % row[2])
	for row: Array in _slider_rows():
		if row[0] == null:
			push_error("RoughnessPanel slider %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("RoughnessPanel value label %s is not assigned in the Inspector" % row[2])
	for row: Array in _check_rows():
		if row[0] == null:
			push_error("RoughnessPanel checkbox %s is not assigned in the Inspector" % row[1])
	for row: Array in _color_rows():
		if row[0] == null:
			push_error("RoughnessPanel colour picker %s is not assigned in the Inspector" % row[1])
	for row: Array in _pick_rows():
		if row[0] == null:
			push_error("RoughnessPanel pick button %s is not assigned in the Inspector" % row[0])
	for fold: Array in _sample_folds():
		if fold[2] == null:
			push_error("RoughnessPanel fold group %s is not assigned in the Inspector" % fold[0])
		if fold[3] == null:
			push_error("RoughnessPanel isolate checkbox %s is not assigned in the Inspector" % fold[0])
	if set_button == null:
		push_error("RoughnessPanel has no Set button assigned in the Inspector")
	if reset_button == null:
		push_error("RoughnessPanel has no Reset button assigned in the Inspector")
