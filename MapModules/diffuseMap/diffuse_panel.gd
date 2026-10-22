class_name DiffusePanel
extends VBoxContainer
## Diffuse map options panel. It keeps the settings Dictionary the generator
## uses, writes the widgets in window order, and regenerates the preview live
## while a slider is dragged, exactly as Unity's immediate-mode window does.
##
## The panel contract is setup() plus `settings_changed` (the shell debounces
## and regenerates), `preview_changed` for the Diffuse Reveal Slider (split
## screen only, no regeneration), and `apply_requested` for "Set as Diffuse".
signal settings_changed()
signal preview_changed()
signal apply_requested()
## Declared for the shell's uniform wiring (`main.gd` connects it for every
## panel). The Diffuse window has no colour picker, so nothing emits it.
signal color_pick_requested()

## Slider rows: [slider node path, settings key, value label path, is_reveal].
## `is_reveal` marks the Diffuse Reveal Slider: Unity applies it only to the
## preview blend (`EditDiffuseGui.cs` lines 495-503), so dragging it re-splits
## the mesh preview instead of regenerating. Value labels use the panel
## pattern (`%.2f`), the same as the Height panel.
# TODO replace fragile direct paths Column/WeightGroup/Row/Presets/Default, with something more robust
const SLIDER_ROWS := [
	["Column/RevealGroup/Reveal", "reveal", "Column/RevealGroup/RevealVal", true],
	["Column/AvgBlurGroup/AvgBlur", "average_blur", "Column/AvgBlurGroup/AvgBlurVal", false],
	["Column/OverlayBlurGroup/OverlayBlur", "overlay_blur", "Column/OverlayBlurGroup/OverlayBlurVal", false],
	["Column/OverlayContrastGroup/OverlayContrast", "overlay_blur_contrast", "Column/OverlayContrastGroup/OverlayContrastVal", false],
	["Column/LightPowerGroup/LightPower", "light_mask_power", "Column/LightPowerGroup/LightPowerVal", false],
	["Column/RemoveLightGroup/RemoveLight", "remove_light", "Column/RemoveLightGroup/RemoveLightVal", false],
	["Column/ShadowPowerGroup/ShadowPower", "shadow_mask_power", "Column/ShadowPowerGroup/ShadowPowerVal", false],
	["Column/RemoveShadowGroup/RemoveShadow", "remove_shadow", "Column/RemoveShadowGroup/RemoveShadowVal", false],
	["Column/HotSpotGroup/HotSpot", "hot_spot_removal", "Column/HotSpotGroup/HotSpotVal", false],
	["Column/DarkSpotGroup/DarkSpot", "dark_spot_removal", "Column/DarkSpotGroup/DarkSpotVal", false],
	["Column/ContrastGroup/Contrast", "final_contrast", "Column/ContrastGroup/ContrastVal", false],
	["Column/BiasGroup/Bias", "final_bias", "Column/BiasGroup/BiasVal", false],
	["Column/KeepColorGroup/KeepColor", "keep_original_color", "Column/KeepColorGroup/KeepColorVal", false],
	["Column/SaturationGroup/Saturation", "saturation", "Column/SaturationGroup/SaturationVal", false],
]

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
	for row: Array in SLIDER_ROWS:
		var slider: Slider = get_node(row[0])
		var value := float(_settings[row[1]])
		slider.value = value
		get_node(row[2]).text = "%.2f" % value
	_syncing = false

## The shell moves the split seam from outside the panel (the reveal slider
## follows the mesh preview).
func set_reveal(value: float) -> void:
	if float(_settings["reveal"]) == value:
		return
	_settings["reveal"] = value
	_syncing = true
	var slider: Slider = get_node("Column/RevealGroup/Reveal")  
	slider.value = value
	get_node("Column/RevealGroup/RevealVal").text = "%.2f" % value
	_syncing = false

func _ready() -> void:
	for row: Array in SLIDER_ROWS:
		(get_node(row[0]) as Slider).value_changed.connect(_on_slider_changed.bind(row))
		# Releasing the grab commits the value once, the way Unity's slider
		# commits on mouse release.
		(get_node(row[0]) as Slider).drag_ended.connect(_on_slider_released.bind(row))
	(get_node("Column/ApplyButton") as Button).pressed.connect(_on_apply_pressed)

func _on_slider_changed(value: float, row: Array) -> void:
	if _settings.is_empty():
		return
	_settings[row[1]] = value
	get_node(row[2]).text = "%.2f" % value
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
