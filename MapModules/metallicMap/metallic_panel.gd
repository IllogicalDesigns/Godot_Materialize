extends Control
class_name MetallicPanel
## Metallic map options panel, laid out like Materialize's window
## (`MetallicGui.cs` `DoMyWindow`, 300 x 530 px), top to bottom:
##
##   " Use Edited Diffuse" / " Use Original Diffuse"   source radio row
##   "Metalic Reveal Slider"                          preview reveal (0..1, 0.5)
##   "Pick Color" + colour swatch, then the five faders
##     Hue, Sat, Lum, Low, High                      0..1 each
##   "Blur Size"                                      0..100, 0
##   "Overlay Blur Size"                              10..100, 30
##   "High Pass Overlay"                              -10..10, 1
##   "Final Contrast"                                 -2..2, 1
##   "Final Bias"                                     -0.5..0.5, 0
##   "Reset Parameters"                               restore every setting
##   "Set as Metallic"
##
## The widgets are authored in `MapModules/metallicMap/metallic_panel.tscn`; every
## widget this script wires is an `@export` assigned in the Inspector, so the
## script holds no node paths (`CODING_RULES.md`). Each export is bound to a
## settings path in the shared settings Dictionary that `MetallicFromDiffuse`
## reads when it generates. Every edit emits `settings_changed` (the shell
## debounces and regenerates), `preview_changed` for the reveal slider (preview
## only, no regeneration), `apply_requested` for "Set as Metallic", and
## `color_pick_requested` asks the shell to sample a colour from the source.
##
## Deviations from Unity: Materialize draws at absolute pixel rects inside a
## draggable window; Godot uses containers, so the groups stretch. Materialize's
## `GuiHelper.Slider` shows the value in an editable text field next to each
## horizontal slider; here every slider gets a value label, including the
## vertical faders, which have no text field in Unity. The swatch is a
## `ColorPicker`, which also lets the user type a colour, while Unity draws an
## 80 x 80 texture of the picked colour and offers only the mesh raycast. Unity
## greys " Use Edited Diffuse" out when no edited diffuse exists; the port's
## Diffuse box always holds the loaded image, so `setup` keeps both boxes live
## (`has_edited` is there for a shell that has none).
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

## The metal colour swatch and "Pick Color".
@export var metal_color_picker: ColorPicker
@export var pick_color_button: Button

## The five comparison faders, in Unity's window order: Hue, Sat, Lum, Low,
## High. The settings key comes from the row's position, not the reversed
## position, because these are five single values and not an equalizer Array.
@export var weight_faders: Array[FaderGroup]

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

## "Set as Metallic".
@export var set_button: Button

## "Reset Parameters", the row above the Set button.
@export var reset_button: Button

## The fader keys, in the order Materialize draws them (`MetallicGui.cs` lines
## 310-323): Hue, Sat, Lum, Low, High.
const FADER_KEYS := ["hue_weight", "sat_weight", "lum_weight", "mask_low", "mask_high"]

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by a MetallicFromDiffuse instance. The panel
## edits it in place, so the tool always sees the current values.
## has_edited: whether the shell has an edited diffuse for " Use Edited
## Diffuse"; Unity greys the box out without one, and forces the pristine
## source on (`MetallicGui.cs` lines 406-408).
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
	_syncing = false

## The main scene picked a colour from the Diffuse preview for the swatch.
func set_sample_color(_sample_index: int, color: Color) -> void:
	_assign(["metal_color"], color)
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
	pick_color_button.pressed.connect(_on_pick_pressed)
	set_button.pressed.connect(_on_set_pressed)
	reset_button.pressed.connect(_on_reset_pressed)

## Rows: [fader group, value label, settings path], built from the exports.
## Unity draws the faders in one row next to the swatch, in Hue / Sat / Lum /
## Low / High order, and each writes one settings key, so the settings index is
## the scene position. Rows share the shape of `_slider_rows`, so the handlers
## read `row[2]` for the settings key and `row[1]` for the value label.
func _fader_rows() -> Array:
	var rows: Array = []
	for i in weight_faders.size():
		var group: FaderGroup = weight_faders[i]
		rows.append([group, group.value_label, [FADER_KEYS[i]]])
	return rows

## Rows: [slider, value label, settings path, preview-only], built from the
## exports, in Materialize's window order.
func _slider_rows() -> Array:
	return [
		[reveal_slider, reveal_label, ["reveal"], true],
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
	]

## Rows: [color picker, settings path].
func _color_rows() -> Array:
	return [
		[metal_color_picker, ["metal_color"]],
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
	# The Metalic Reveal Slider is preview-only, so it does not need a
	# regeneration: the shell moves the seam on the mesh preview instead.
	if row.size() > 3 and row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_check_changed(toggled: bool, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], toggled)
	_enforce_source_row()
	if not _syncing:
		settings_changed.emit()

## Materialize's source row is a radio pair: `GUI.Toggle` on " Use Edited
## Diffuse" turns " Use Original Diffuse" off, and vice versa
## (`MetallicGui.cs` lines 287-295), so at least one source is always on. If
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

func _on_color_changed(color: Color, row: Array) -> void:
	if _settings.is_empty():
		return
	_assign(row[1], color)
	if not _syncing:
		settings_changed.emit()

func _on_pick_pressed() -> void:
	# Unity's "Pick Color" arms a mesh raycast; the port asks the shell for the
	# colour under the next click on the Diffuse box preview, the same single
	# sample slot the Height panel uses.
	color_pick_requested.emit(1)

func _on_set_pressed() -> void:
	if _settings.is_empty():
		return
	apply_requested.emit()

func _on_reset_pressed() -> void:
	if _settings.is_empty():
		return
	reset_requested.emit()

## Reads a settings value at a path, e.g. ["metal_color"] or ["mask_low"].
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
			push_error("MetallicPanel fader %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("MetallicPanel value label %s is not assigned in the Inspector" % row[2])
	for row: Array in _slider_rows():
		if row[0] == null:
			push_error("MetallicPanel slider %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("MetallicPanel value label %s is not assigned in the Inspector" % row[2])
	for row: Array in _check_rows():
		if row[0] == null:
			push_error("MetallicPanel checkbox %s is not assigned in the Inspector" % row[1])
	for row: Array in _color_rows():
		if row[0] == null:
			push_error("MetallicPanel colour picker %s is not assigned in the Inspector" % row[1])
	if pick_color_button == null:
		push_error("MetallicPanel has no Pick Color button assigned in the Inspector")
	if set_button == null:
		push_error("MetallicPanel has no Set button assigned in the Inspector")
	if reset_button == null:
		push_error("MetallicPanel has no Reset button assigned in the Inspector")
