extends VBoxContainer
class_name FaderGroup
## One vertical fader row: a name label, a `VSlider`, and its value label. The
## panel exports arrays of these (`Array[FaderGroup]`) in the order Materialize
## draws them, and the settings key comes from the row's position in the array.
##
## The fader nodes are authored in the panel scene, and the Inspector assigns
## the slider and the value label on each row, so no script holds a node path
## (`CODING_RULES.md`): renaming a widget in the scene tree keeps the reference
## pointing at it.

@export var slider: Slider
@export var value_label: Label

## Writes a settings value into the row, label included.
func set_value(value: float) -> void:
	slider.value = value
	value_label.text = "%.2f" % value

## The row's current slider value.
func get_value() -> float:
	return slider.value
