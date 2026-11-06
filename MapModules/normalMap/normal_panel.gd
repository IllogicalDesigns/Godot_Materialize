extends Control
class_name NormalPanel
## Normal From Height tool panel, laid out like Materialize's window
## (`NormalFromHeightGui.cs` `DoMyWindow`, 300 x 630 px), top to bottom:
##
##   "Normal Reveal Slider"                    preview reveal (0..1, 0.5)
##   "Pre Contrast"                            0..50, 20
##   "Frequency Equalizer"                     7 vertical faders, Blur6 (left)
##                                             to Blur0 (right), 0..1, +
##                                             "Presets" Default / Smooth /
##                                             Crisp / Mids
##   "Angular Intensity"                       0..1, 0.5
##   "Angularity Amount"                       0..1, 0
##   " Shape from Diffuse (Uncheked from Height)"
##   " Shape Recognition, Rotation, Spread, Bias" then
##     Shape Recognition 0..1, Light Rotation -3.14..3.14,
##     Slope Blur 5..100, Shape Bias 0..1
##   "Final Contrast"                          0..10, 5
##   "Reset Parameters"                        restore every setting
##   "Set as Normal Map"
##
## The widgets are authored in `MapModules/normalMap/normal_panel.tscn`; every
## widget this script wires is an `@export` assigned in the Inspector, so the
## script holds no node paths (`CODING_RULES.md`). Each export is bound to a
## settings path in the shared settings Dictionary that `NormalFromHeight`
## reads when it generates. Every edit emits `settings_changed` (the shell
## debounces and regenerates), `preview_changed` for the reveal slider (preview
## only, no regeneration), and `apply_requested` for "Set as Normal Map".
##
## Deviations from Unity: Materialize draws at absolute pixel rects inside a
## draggable window; Godot uses containers, so the groups stretch. Materialize's
## `GuiHelper.Slider` shows the value in an editable text field next to each
## horizontal slider; here every slider gets a value label, including the
## vertical faders, which have no text field in Unity. Unity enables the
## "Shape from Diffuse" box only while a diffuse map exists; the shell disables
## the box in the same way (`setup`).

signal settings_changed()
signal preview_changed()
signal apply_requested()
## "Reset Parameters" asks the shell to restore this map's settings Dictionary
## to its defaults. The panel owns no settings knowledge here: the shell resets
## the Dictionary, refreshes the widgets, and regenerates.
signal reset_requested()

## The Reveal pair: the preview slider and its value label.
@export var reveal_slider: Slider
@export var reveal_label: Label

## The frequency equalizer faders, in scene order. Faders run coarse (Blur6,
## leftmost) to fine (Blur0, rightmost), exactly as Materialize places them;
## the settings key is `weights` indexed by the reversed position.
@export var weight_faders: Array[FaderGroup]

## The preset buttons, in Unity's column order.
@export var preset_default_button: Button
@export var preset_smooth_button: Button
@export var preset_crisp_button: Button
@export var preset_mids_button: Button

## The single slider pairs, in Materialize's window order.
@export var pre_contrast_slider: Slider
@export var pre_contrast_label: Label
@export var angular_intensity_slider: Slider
@export var angular_intensity_label: Label
@export var angularity_slider: Slider
@export var angularity_label: Label
@export var shape_recognition_slider: Slider
@export var shape_recognition_label: Label
@export var light_rotation_slider: Slider
@export var light_rotation_label: Label
@export var slope_blur_slider: Slider
@export var slope_blur_label: Label
@export var shape_bias_slider: Slider
@export var shape_bias_label: Label
@export var final_contrast_slider: Slider
@export var final_contrast_label: Label

## " Shape from Diffuse (Uncheked from Height)".
@export var use_diffuse_check: CheckBox

## "Set as Normal Map".
@export var set_button: Button

## "Reset Parameters", the row above the Set button.
@export var reset_button: Button

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a NormalFromHeight instance. The panel
## edits it in place, so the tool always sees the current values.
## has_diffuse: whether the shell has a source for "Shape from Diffuse"; Unity
## greys the box out with no diffuse map and forces the setting off.
func setup(settings: Dictionary, has_diffuse: bool = true) -> void:
	_settings = settings
	use_diffuse_check.disabled = not has_diffuse
	if not has_diffuse:
		_settings["use_diffuse"] = false
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
	_syncing = false

func _ready() -> void:
	_check_exports()
	for row: Array in _fader_rows():
		row[0].slider.value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in _slider_rows():
		row[0].value_changed.connect(_on_slider_changed.bind(row))
	for row: Array in _check_rows():
		row[0].toggled.connect(_on_check_changed.bind(row))
	for row: Array in _preset_rows():
		row[0].pressed.connect(_on_preset_pressed.bind(row))
	set_button.pressed.connect(_on_set_pressed)
	reset_button.pressed.connect(_on_reset_pressed)

## Rows: [fader group, value label, settings path], built from the exports. The
## faders store the coarse-to-fine scene order in the settings Array, so the
## settings index is the reversed position. Rows share the shape of
## `_slider_rows`, so the handlers read `row[2]` for the settings key and
## `row[1]` for the value label.
func _fader_rows() -> Array:
	var rows: Array = []
	for i in weight_faders.size():
		var group: FaderGroup = weight_faders[i]
		rows.append([group, group.value_label, ["weights", weight_faders.size() - 1 - i]])
	return rows

## Rows: [slider, value label, settings path, preview-only], built from the
## exports, in Materialize's window order.
func _slider_rows() -> Array:
	return [
		[reveal_slider, reveal_label, ["reveal"], true],
		[pre_contrast_slider, pre_contrast_label, ["pre_contrast"]],
		[angular_intensity_slider, angular_intensity_label, ["angular_intensity"]],
		[angularity_slider, angularity_label, ["angularity"]],
		[shape_recognition_slider, shape_recognition_label, ["shape_recognition"]],
		[light_rotation_slider, light_rotation_label, ["light_rotation"]],
		[slope_blur_slider, slope_blur_label, ["slope_blur"]],
		[shape_bias_slider, shape_bias_label, ["shape_bias"]],
		[final_contrast_slider, final_contrast_label, ["final_contrast"]],
	]

## Rows: [checkbox, settings path].
func _check_rows() -> Array:
	return [
		[use_diffuse_check, ["use_diffuse"]],
	]

## Rows: [button, preset name]. Labels are Materialize's button strings:
## Default / Smooth / Crisp / Mids.
func _preset_rows() -> Array:
	return [
		[preset_default_button, "default"],
		[preset_smooth_button, "smooth"],
		[preset_crisp_button, "crisp"],
		[preset_mids_button, "mids"],
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
	# The Normal Reveal Slider is preview-only, so it does not need a
	# regeneration: the shell moves the seam on the mesh preview instead.
	if row.size() > 3 and row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_check_changed(toggled: bool, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], toggled)
	if not _syncing:
		settings_changed.emit()

func _on_set_pressed() -> void:
	if _settings.is_empty():
		return
	apply_requested.emit()

func _on_reset_pressed() -> void:
	if _settings.is_empty():
		return
	reset_requested.emit()

func _on_preset_pressed(row: Array) -> void:
	if _settings.is_empty():
		return
	_settings["weights"] = (NormalFromHeight.PRESET_WEIGHTS[row[1]] as Array).duplicate()
	refresh()
	if not _syncing:
		settings_changed.emit()

## Reads a settings value at a path, e.g. ["weights", 3]. The node is Variant,
## not Dictionary, because a settings path can end at an Array element.
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
			push_error("NormalPanel fader %s is not assigned in the Inspector" % row[2])
	for row: Array in _slider_rows():
		if row[0] == null:
			push_error("NormalPanel slider %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("NormalPanel value label %s is not assigned in the Inspector" % row[2])
	for row: Array in _check_rows():
		if row[0] == null:
			push_error("NormalPanel checkbox %s is not assigned in the Inspector" % row[1])
	for row: Array in _preset_rows():
		if row[0] == null:
			push_error("NormalPanel preset button %s is not assigned in the Inspector" % row[1])
	if set_button == null:
		push_error("NormalPanel has no Set button assigned in the Inspector")
	if reset_button == null:
		push_error("NormalPanel has no Reset button assigned in the Inspector")
