extends PanelContainer
class_name MapBox
## One map slot box, mirroring Materialize's main GUI boxes (`MainGui.cs`):
## a titled box with a preview, Paste / Copy / Open / Save, Quick Save, Preview,
## and Create / Clear. Materialize draws `GUI.Box(..., "Height Map")` plus a
## 100x100 `GUI.DrawTexture` and the same button set for every map.
##
## The box is generic: `map_type` says which map it holds ("height", "diffuse",
## ...), and the main scene decides what each button does. The preview forwards
## clicks as `preview_clicked` with the UV inside the drawn image, so colour
## picking works on any preview in the app.
##
## Every widget the box wires is an `@export` assigned in the Inspector (see
## `scenes/map_panel.tscn`), so this script holds no node paths
## (`CODING_RULES.md`).

signal button_pressed(action: String, map_type: String)
signal preview_clicked(map_type: String, uv: Vector2)

@export var map_type: String = ""
@export var title: String = "Map"
@export var create_label: String = "Create"

## The title, the Create button, and the preview, assigned in the Inspector.
@export var title_label: Label
@export var create_button: Button
@export var preview: TextureRect

## The button rows: Paste / Copy / Open / Save, Quick Save, Preview, Create,
## Clear, the same set Materialize draws for every map.
@export var paste_button: Button
@export var copy_button: Button
@export var open_button: Button
@export var save_button: Button
@export var quick_save_button: Button
@export var preview_button: Button
@export var clear_button: Button

## action -> button, built from the exports in `_ready`.
var _buttons: Dictionary = {}

func _ready() -> void:
	_check_exports()
	title_label.text = title
	create_button.text = create_label
	preview.gui_input.connect(_on_preview_gui_input)
	_buttons = {
		"paste": paste_button,
		"copy": copy_button,
		"open": open_button,
		"save": save_button,
		"quick_save": quick_save_button,
		"preview": preview_button,
		"create": create_button,
		"clear": clear_button,
	}
	for action: String in _buttons:
		(_buttons[action] as Button).pressed.connect(_on_button.bind(action))

## Shows an image in the box. Accepts any format; null clears the preview.
func set_image(image: Image) -> void:
	if image == null:
		preview.texture = null
		return
	preview.texture = ImageTexture.create_from_image(Blit.to_display(image))

## Re-applies the title and create label after _ready, so the shell can name a
## box once it knows which map it holds. The instance exports are read in
## _ready, which runs before the shell's _ready.
func set_labels(new_title: String, new_create_label: String) -> void:
	title = new_title
	create_label = new_create_label
	title_label.text = title
	create_button.text = create_label

## Materialize greys buttons out with GUI.enabled; this is the same thing.
func set_button_enabled(action: String, enabled: bool) -> void:
	(_buttons[action] as Button).disabled = not enabled

func _on_button(action: String) -> void:
	button_pressed.emit(action, map_type)

func _on_preview_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if preview.texture == null:
		return
	var uv := click_uv(event.position, preview.size, preview.texture.get_size())
	if uv.x < 0.0:
		return
	preview_clicked.emit(map_type, uv)

## Maps a click inside a keep-aspect-centred TextureRect to the image UV.
## Returns (-1, -1) when the click falls in the letterbox around the image.
static func click_uv(position: Vector2, rect: Vector2, texture_size: Vector2i) -> Vector2:
	if rect.x <= 0.0 or rect.y <= 0.0 or texture_size.x <= 0 or texture_size.y <= 0:
		return Vector2(-1.0, -1.0)
	var size := Vector2(texture_size)
	var scale := minf(rect.x / size.x, rect.y / size.y)
	var drawn := size * scale
	var local: Vector2 = position - (rect - drawn) * 0.5
	if local.x < 0.0 or local.y < 0.0 or local.x > drawn.x or local.y > drawn.y:
		return Vector2(-1.0, -1.0)
	return local / drawn

## Reports exports that were never assigned in the Inspector, so a missing
## widget shows up as an error at load instead of a null crash mid-run.
func _check_exports() -> void:
	for name: String in ["title_label", "create_button", "preview", "paste_button",
			"copy_button", "open_button", "save_button", "quick_save_button",
			"preview_button", "clear_button"]:
		if get(name) == null:
			push_error("MapBox export %s is not assigned in scenes/map_panel.tscn" % name)
