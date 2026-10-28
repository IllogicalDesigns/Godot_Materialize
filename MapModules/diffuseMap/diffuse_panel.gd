class_name DiffusePanel
extends VBoxContainer
## Diffuse map options panel. It keeps the settings Dictionary the generator
## uses, writes the widgets in window order, and regenerates the preview live
## while a slider is dragged, exactly as Unity's immediate-mode window does.
##
## The panel contract is setup() plus `settings_changed` (the shell debounces
## and regenerates), `preview_changed` for the Diffuse Reveal Slider (split
## screen only, no regeneration), and `apply_requested` for "Set as Diffuse".
##
## Every slider and value label is an `@export` assigned in the Inspector (see
## `MapModules/diffuseMap/diffuse_panel.tscn`), so this script holds no node
## paths (`CODING_RULES.md`).
signal settings_changed()
signal preview_changed()
signal apply_requested()
## "Reset Parameters" asks the shell to restore this map's settings Dictionary
## to its defaults. The panel owns no settings knowledge here: the shell resets
## the Dictionary, refreshes the widgets, and regenerates.
signal reset_requested()
## Declared for the shell's uniform wiring (`main.gd` connects it for every
## panel). The Diffuse window has no colour picker, so nothing emits it.
signal color_pick_requested()

## The slider pairs, in Materialize's window order. The Reveal pair is marked
## `is_reveal`: Unity applies it only to the preview blend (`EditDiffuseGui.cs`
## lines 495-503), so dragging it re-splits the mesh preview instead of
## regenerating. Value labels use the panel pattern (`%.2f`), the same as the
## Height panel.
@export var reveal_slider: Slider
@export var reveal_label: Label
@export var avg_blur_slider: Slider
@export var avg_blur_label: Label
@export var overlay_blur_slider: Slider
@export var overlay_blur_label: Label
@export var overlay_contrast_slider: Slider
@export var overlay_contrast_label: Label
@export var light_power_slider: Slider
@export var light_power_label: Label
@export var remove_light_slider: Slider
@export var remove_light_label: Label
@export var shadow_power_slider: Slider
@export var shadow_power_label: Label
@export var remove_shadow_slider: Slider
@export var remove_shadow_label: Label
@export var hot_spot_slider: Slider
@export var hot_spot_label: Label
@export var dark_spot_slider: Slider
@export var dark_spot_label: Label
@export var contrast_slider: Slider
@export var contrast_label: Label
@export var bias_slider: Slider
@export var bias_label: Label
@export var keep_color_slider: Slider
@export var keep_color_label: Label
@export var saturation_slider: Slider
@export var saturation_label: Label

## "Set as Diffuse".
@export var apply_button: Button

## "Reset Parameters", the row above the Apply button.
@export var reset_button: Button

var _settings: Dictionary = {}
## Set while widgets are being re-synced from settings, so writing a value back
## into the settings Dictionary does not trigger another generation.
var _syncing := false

## settings: the Dictionary owned by the DiffuseGenerator instance. The panel
## edits it in place, so the tool always sees the current values.
func setup(settings: Dictionary) -> void:
	_settings = settings
	refresh()

## Push the settings Dictionary into the widgets.
func refresh() -> void:
	_syncing = true
	for row: Array in _slider_rows():
		var value := float(_settings[row[1]])
		row[0].value = value
		row[2].text = "%.2f" % value
	_syncing = false

## The shell moves the split seam from outside the panel (the reveal slider
## follows the mesh preview).
func set_reveal(value: float) -> void:
	if float(_settings["reveal"]) == value:
		return
	_settings["reveal"] = value
	_syncing = true
	reveal_slider.value = value
	reveal_label.text = "%.2f" % value
	_syncing = false

func _ready() -> void:
	_check_exports()
	for row: Array in _slider_rows():
		row[0].value_changed.connect(_on_slider_changed.bind(row))
		# Releasing the grab commits the value once, the way Unity's slider
		# commits on mouse release.
		row[0].drag_ended.connect(_on_slider_released.bind(row))
	apply_button.pressed.connect(_on_apply_pressed)
	reset_button.pressed.connect(_on_reset_pressed)

## Rows: [slider, settings key, value label, is_reveal], built from the exports.
func _slider_rows() -> Array:
	return [
		[reveal_slider, "reveal", reveal_label, true],
		[avg_blur_slider, "average_blur", avg_blur_label, false],
		[overlay_blur_slider, "overlay_blur", overlay_blur_label, false],
		[overlay_contrast_slider, "overlay_blur_contrast", overlay_contrast_label, false],
		[light_power_slider, "light_mask_power", light_power_label, false],
		[remove_light_slider, "remove_light", remove_light_label, false],
		[shadow_power_slider, "shadow_mask_power", shadow_power_label, false],
		[remove_shadow_slider, "remove_shadow", remove_shadow_label, false],
		[hot_spot_slider, "hot_spot_removal", hot_spot_label, false],
		[dark_spot_slider, "dark_spot_removal", dark_spot_label, false],
		[contrast_slider, "final_contrast", contrast_label, false],
		[bias_slider, "final_bias", bias_label, false],
		[keep_color_slider, "keep_original_color", keep_color_label, false],
		[saturation_slider, "saturation", saturation_label, false],
	]

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	_settings[row[1]] = value
	row[2].text = "%.2f" % value
	if _syncing:
		return
	# The Diffuse Reveal Slider is preview-only, so it does not need a
	# regeneration: the shell re-splits the preview instead.
	if row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_slider_released(_value: float, row: Array) -> void:
	if _settings.is_empty() or _syncing:
		return
	if row[3]:
		preview_changed.emit()
	else:
		settings_changed.emit()

func _on_apply_pressed() -> void:
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
			push_error("DiffusePanel slider %s is not assigned in the Inspector" % row[1])
		elif row[2] == null:
			push_error("DiffusePanel value label %s is not assigned in the Inspector" % row[1])
	if apply_button == null:
		push_error("DiffusePanel has no Apply button assigned in the Inspector")
	if reset_button == null:
		push_error("DiffusePanel has no Reset button assigned in the Inspector")
