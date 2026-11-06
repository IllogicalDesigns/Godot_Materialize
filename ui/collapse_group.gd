extends VBoxContainer
class_name CollapseGroup
## A foldable container: a header row with a `+` / `-` button, and a body that
## hides when the group is folded. Materialize's windows have no fold control -
## `HeightFromDiffuseGui.cs` `DoMyWindow` draws every control at a fixed pixel
## rect inside a 300 x 590 px window, and a sample block disappears only when
## its `UseSample1` toggle goes off (lines 714-751, 760-797) - so folding is
## port-only: Godot stacks the groups in a column, and the two colour sample
## blocks are 110 px of faders each, which pushes "Set as Height Map" below the
## panel.
##
## The panel authors the group's own children (see
## `MapModules/heightMap/height_panel.tscn`). The contract is three exports
## assigned in the Inspector - the fold button, the header row, and the body -
## so this script holds no node paths (`CODING_RULES.md`):
##
##   Header  HBoxContainer, first child `Fold` (the toggle button), then any
##           widgets that must stay reachable while the body is hidden. The
##           Height panel puts "Use Color Sample N" and "Isolate Mask" here.
##   Body    the controls that fold away (swatch, Pick Color, the faders).
##
## Header widgets keep working while the body is hidden, which is what the
## checkboxes need: a sample can be turned on and off without opening it.

signal collapsed_changed(collapsed: bool)

## Folded by default, matching Materialize's default settings
## (`HeightFromDiffuseSettings`: `UseSample1` / `UseSample2` start false).
@export var collapsed: bool = true:
	set(value):
		if value == collapsed:
			return
		collapsed = value
		_apply()

## The fold button, the header row, and the body that hides (assigned in the
## Inspector).
@export var fold_button: Button
@export var header: Container
@export var body: VBoxContainer

## The button labels. Godot's fallback font has `+` and `-` and no arrow
## glyphs, so the port uses the ASCII pair.
const FOLD_LABEL := "+"
const UNFOLD_LABEL := "-"

## Set while the button's `button_pressed` is being written from the fold state,
## so the resulting `toggled` signal does not loop back into the setter.
var _syncing := false

func _ready() -> void:
	if fold_button == null:
		push_error("CollapseGroup has no fold button assigned in the Inspector")
		return
	if body == null:
		push_error("CollapseGroup has no body assigned in the Inspector")
		return
	fold_button.toggle_mode = true
	fold_button.tooltip_text = "Fold / unfold these controls"
	fold_button.toggled.connect(_on_fold_toggled)
	_apply()

## Folds or unfolds the body. The Height panel calls this when "Use Color
## Sample N" goes off, the way Unity stops drawing that sample's block.
func set_collapsed(value: bool) -> void:
	collapsed = value

func _on_fold_toggled(pressed: bool) -> void:
	if _syncing:
		return
	# The button reads as pressed while the body is open, so pressed off folds.
	set_collapsed(not pressed)

func _apply() -> void:
	if fold_button == null or body == null:
		return
	body.visible = not collapsed
	_syncing = true
	fold_button.button_pressed = not collapsed
	_syncing = false
	fold_button.text = FOLD_LABEL if collapsed else UNFOLD_LABEL
	collapsed_changed.emit(collapsed)
