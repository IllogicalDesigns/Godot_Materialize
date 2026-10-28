extends Control
class_name AOPanel
## AO Map options panel, laid out like Materialize's window
## (`AOFromNormalGui.cs` `DoMyWindow`, 300 x 280 px), top to bottom:
##
##   "AO pixel Spread"                        10..100, 50
##   "Pixel Depth"                            0..256, 100
##   "Blend Normal AO and Depth AO"           0..1, 1 (0 without a height map)
##   "AO Power"                               0.1..10, 1
##   "AO Bias"                                -1..1, 0
##   "Reset Parameters"                       restore every setting
##   "Set as AO Map"
##
## The widgets are authored in `MapModules/aoMap/ao_panel.tscn`; every widget
## this script wires is an `@export` assigned in the Inspector, so the script
## holds no node paths (`CODING_RULES.md`). Each slider is bound to its key in
## the shared settings Dictionary that `AOFromNormal` reads when it generates,
## the same Dictionary the Metallic panel edits in place.
##
## Deviations from Unity: Unity regenerates the accumulation only when "AO
## pixel Spread" or "Pixel Depth" moves (`AOFromNormalGui.cs` lines 173-181,
## `doStuff = true`); Blend, AO Power and AO Bias are preview-material uniforms
## applied every frame (lines 159-161) and baked only at Set time (pass 8). The
## port bakes the final grade inside the combine pass, so every slider emits
## `settings_changed` and the shell's debounce re-runs the chain on the settle,
## which is how the Metallic panel behaves. Unity's AO window has no reveal
## slider, so this panel has no `preview_changed`, and the tool samples no
## colours, so it has no `color_pick_requested`.

signal settings_changed()
signal apply_requested()
## "Reset Parameters" asks the shell to restore this map's settings Dictionary
## to its defaults. The panel owns no settings knowledge here: the shell resets
## the Dictionary, refreshes the widgets, and regenerates.
signal reset_requested()

## The slider pairs, in Materialize's window order.
@export var spread_slider: Slider
@export var spread_label: Label
@export var depth_slider: Slider
@export var depth_label: Label
@export var blend_slider: Slider
@export var blend_label: Label
@export var contrast_slider: Slider
@export var contrast_label: Label
@export var bias_slider: Slider
@export var bias_label: Label

## "Set as AO Map".
@export var set_button: Button

## "Reset Parameters", the row above the Set button.
@export var reset_button: Button

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by an `AOFromNormal` instance. The panel
## edits it in place, so the tool always sees the current values.
## has_height: Unity opens the window with Blend 1 when a height map exists
## and Blend 0 when it does not (`InitializeSettings` lines 108-114): without
## a height map the depth term reads fully occluded on Unity's flat default
## height, so the blend is forced off. The slider itself stays live in both
## cases (`GuiHelper.Slider` has no `GUI.enabled` guard, line 183).
func setup(settings: Dictionary, has_height: bool = true) -> void:
	_settings = settings
	if not has_height:
		_settings["blend"] = 0.0
	refresh()

## Push the settings Dictionary into the widgets. The rows share the metallic
## panel's shape, [slider, value label, settings key], so one loop covers all
## five pairs.
func refresh() -> void:
	_syncing = true
	for row: Array in _slider_rows():
		var value := float(_settings[row[2][0]])
		row[0].value = value
		row[1].text = "%.2f" % value
	_syncing = false

func _ready() -> void:
	_check_exports()
	for row: Array in _slider_rows():
		row[0].value_changed.connect(_on_slider_changed.bind(row))
	set_button.pressed.connect(_on_set_pressed)
	reset_button.pressed.connect(_on_reset_pressed)

## Rows: [slider, value label, settings key], built from the exports, in
## Materialize's window order.
func _slider_rows() -> Array:
	return [
		[spread_slider, spread_label, ["spread"]],
		[depth_slider, depth_label, ["depth"]],
		[blend_slider, blend_label, ["blend"]],
		[contrast_slider, contrast_label, ["final_contrast"]],
		[bias_slider, bias_label, ["final_bias"]],
	]

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	_settings[row[2][0]] = value
	if _syncing:
		return
	row[1].text = "%.2f" % value
	settings_changed.emit()

func _on_set_pressed() -> void:
	if _settings.is_empty():
		return
	apply_requested.emit()

func _on_reset_pressed() -> void:
	if _settings.is_empty():
		return
	reset_requested.emit()

## Reports exports that were never assigned in the Inspector, so a missing
## widget shows up as an error at load instead of a null crash mid-edit.
func _check_exports() -> void:
	for row: Array in _slider_rows():
		if row[0] == null:
			push_error("AOPanel slider %s is not assigned in the Inspector" % row[2])
		elif row[1] == null:
			push_error("AOPanel value label %s is not assigned in the Inspector" % row[2])
	if set_button == null:
		push_error("AOPanel has no Set button assigned in the Inspector")
	if reset_button == null:
		push_error("AOPanel has no Reset button assigned in the Inspector")
