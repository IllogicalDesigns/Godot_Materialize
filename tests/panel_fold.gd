extends Node
## Layout and interaction check for the Height panel's foldable colour sample
## groups (`ui/collapse_group.gd`). Folding a sample must hide its swatch,
## "Pick Color", and the six faders, keep the header's checkboxes reachable, and
## keep "Set as Height Map" inside the window.
##
## It instantiates the real main scene, then drives the panel the way a user
## does, printing the geometry at four states:
##
##   1. both samples folded - the default, since `UseSample1` / `UseSample2`
##      start off, and Unity draws neither sample block
##      (`HeightFromDiffuseGui.cs` lines 714-751, 760-797)
##   2. both sample bodies open
##   3. Sample 2 closed by turning its "Use Color Sample 2" box off
##   4. Sample 2 opened again with its fold button, while Use 2 is still off
##
## The checks are: the fold follows `use`, "Isolate Mask" is greyed out with its
## sample, a folded group is only its header row, the fold button opens the body
## without touching the settings, and the panel fits the window when the samples
## are folded and overflows it when they are open, which is the bug being fixed.
##
## Layout only, so it runs headless:
##   godot --headless --path . res://tests/panel_fold.tscn
## A real display works too (the shell then generates the stone source first).

const WARMUP_FRAMES := 5

var _main: Node3D
var _panel: Control
var _frames := 0
var _phase := 0
## phase -> the panel size the layout demanded at that state.
var _sizes: Dictionary = {}

const PHASE_WARMUP := 0
const PHASE_OPEN := 1
const PHASE_USE_OFF := 2
const PHASE_BUTTON_OPEN := 3

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return
	match _phase:
		PHASE_WARMUP:
			_panel = _main._panel_slot.get_child(0)
			_report("state 1: both samples folded (Use off, the default)")
			_set_use(1, true)
			_set_use(2, true)
			_next(PHASE_OPEN)
		PHASE_OPEN:
			_report("state 2: both sample bodies open")
			_set_use(2, false)
			_next(PHASE_USE_OFF)
		PHASE_USE_OFF:
			_report("state 3: Use 2 turned off from its checkbox")
			_checks_use_off()
			_click_fold(2)
			_next(PHASE_BUTTON_OPEN)
		PHASE_BUTTON_OPEN:
			_report("state 4: Sample 2 opened with its fold button, Use 2 still off")
			_checks_button()
			_fit()
			get_tree().quit()

func _next(phase: int) -> void:
	_phase = phase
	_frames = 0

## Presses a sample's "Use Color Sample N" checkbox the way a click does: the
## `toggled` signal is what the panel listens to, and setting `button_pressed`
## first keeps the box's visual state in step with the settings.
func _set_use(sample: int, on: bool) -> void:
	var check: CheckBox = _panel.get_node("Column/Sample%dGroup/Header/Use%d" % [sample, sample])
	check.button_pressed = on
	check.emit_signal("toggled", on)

## Presses a sample's fold button the way a click does, on the `toggled` signal
## the group listens to.
func _click_fold(sample: int) -> void:
	var fold: Button = _panel.get_node("Column/Sample%dGroup/Header/Fold" % sample)
	fold.button_pressed = not fold.button_pressed
	fold.emit_signal("toggled", fold.button_pressed)

## Prints the panel column, the two fold groups, and the Set button, so the
## height and width each fold saves is readable from the output.
func _report(caption: String) -> void:
	print("panel_fold: ", caption)
	print("  panel size ", _panel.size, " in slot ", _main._panel_slot.size,
		", window ", get_tree().root.size)
	for sample: int in [1, 2]:
		var group: CollapseGroup = _panel.get_node("Column/Sample%dGroup" % sample)
		var header: Control = _panel.get_node("Column/Sample%dGroup/Header" % sample)
		var body: Control = _panel.get_node("Column/Sample%dGroup/Body" % sample)
		print("  sample ", sample, ": collapsed=", group.collapsed,
			" group=", group.size, " header=", header.size,
			" body visible=", body.visible, " body=", body.size)
	var set_button: Button = _panel.get_node("Column/SetButton")
	var rect: Rect2 = set_button.get_global_rect()
	print("  Set as Height Map: top ", rect.position.y, " bottom ", rect.end.y,
		" panel bottom ", _panel.get_global_rect().end.y)
	_sizes[_phase] = _panel.size

## The settings / header checks at state 3, where Use 2 has just gone off.
func _checks_use_off() -> void:
	var sample1: CollapseGroup = _panel.get_node("Column/Sample1Group")
	var sample2: CollapseGroup = _panel.get_node("Column/Sample2Group")
	var sample2_header: Control = _panel.get_node("Column/Sample2Group/Header")
	var use1: bool = bool(_main._active.settings()["sample1"]["use"])
	var use2: bool = bool(_main._active.settings()["sample2"]["use"])
	var isolate1: CheckBox = _panel.get_node("Column/Sample1Group/Header/Isolate1")
	var isolate2: CheckBox = _panel.get_node("Column/Sample2Group/Header/Isolate2")

	print("panel_fold checks (Use boxes):")
	_check("sample 1 open because Use 1 is on", not sample1.collapsed, use1)
	_check("sample 2 folded because Use 2 is off", sample2.collapsed, not use2)
	_check("Isolate 1 enabled with its sample", not isolate1.disabled, use1)
	_check("Isolate 2 greyed out with its sample", isolate2.disabled, not use2)
	# A folded group is only its header row: the swatch, "Pick Color", and the
	# six faders come out of the column.
	_check("folded group is only its header row", sample2.size.y == sample2_header.size.y,
		true)

## The fold button checks at state 4, where the button has opened Sample 2 while
## its Use box is still off. Folding is a layout control, so it must not write
## settings: a user can look at the faders of a sample they have switched off.
func _checks_button() -> void:
	var sample2: CollapseGroup = _panel.get_node("Column/Sample2Group")
	var sample2_body: Control = _panel.get_node("Column/Sample2Group/Body")
	var isolate2: CheckBox = _panel.get_node("Column/Sample2Group/Header/Isolate2")
	var use2: bool = bool(_main._active.settings()["sample2"]["use"])

	print("panel_fold checks (fold button):")
	_check("the fold button opens the body", not sample2.collapsed, true)
	_check("the body becomes visible", sample2_body.visible, true)
	_check("the fold button does not switch the sample on", not use2, true)
	_check("Isolate 2 stays greyed out", isolate2.disabled, true)

## The width and height the open sample rows demand, measured against the window
## the app opens at (`display/window/size/viewport_height`): a headless run
## reports a 64 x 64 root window, and the sizes a container demands are the same
## in both, which is what the check is about.
func _fit() -> void:
	var ui: MarginContainer = _main.get_node("UI")
	var window_height := float(int(ProjectSettings.get_setting("display/window/size/viewport_height")))
	var top := float(int(ui.get_theme_constant("margin_top")))
	var bottom := float(int(ui.get_theme_constant("margin_bottom")))
	var folded: Vector2 = _sizes[PHASE_WARMUP]
	var open: Vector2 = _sizes[PHASE_OPEN]

	print("panel_fold checks (fit):")
	print("  panel height folded ", folded.y, " open ", open.y,
		" saved %.0f px" % [open.y - folded.y])
	print("  window height ", window_height, " usable ", window_height - top - bottom)
	_check("folded panel fits the window", top + folded.y <= window_height, true)
	_check("open samples overflow the window, the bug being fixed",
		top + open.y > window_height, true)
	_check("folding keeps the panel at its 400 px minimum width", folded.x <= 400.0, true)
	_check("open sample rows widen the panel past 400 px", open.x > 400.0, true)

func _check(caption: String, got: bool, expected: bool) -> void:
	var ok: bool = got == expected
	print("  [", "PASS" if ok else "FAIL", "] ", caption,
		" got=", got, " expect=", expected)
