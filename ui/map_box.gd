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

signal button_pressed(action: String, map_type: String)
signal preview_clicked(map_type: String, uv: Vector2)

@export var map_type: String = ""
@export var title: String = "Map"
@export var create_label: String = "Create"

## action -> node path, matching Materialize's button rows.
const BUTTONS := {
	"paste": "Box/IOSrow/Paste",
	"copy": "Box/IOSrow/Copy",
	"open": "Box/IOSrow/Open",
	"save": "Box/IOSrow/Save",
	"quick_save": "Box/Quickrow/QuickSave",
	"preview": "Box/Quickrow/Preview",
	"create": "Box/Createrow/Create",
	"clear": "Box/Createrow/Clear",
}

var _preview: TextureRect
var _buttons: Dictionary = {}

func _ready() -> void:
	$Box/Title.text = title
	$Box/Createrow/Create.text = create_label
	_preview = $Box/Preview
	_preview.gui_input.connect(_on_preview_gui_input)
	for action: String in BUTTONS:
		var button: Button = get_node(BUTTONS[action])
		_buttons[action] = button
		button.pressed.connect(_on_button.bind(action))

## Shows an image in the box. Accepts any format; null clears the preview.
func set_image(image: Image) -> void:
	if image == null:
		_preview.texture = null
		return
	_preview.texture = ImageTexture.create_from_image(Blit.to_display(image))

## Re-applies the title and create label after _ready, so the shell can name a
## box once it knows which map it holds. The instance exports are read in
## _ready, which runs before the shell's _ready.
func set_labels(new_title: String, new_create_label: String) -> void:
	title = new_title
	create_label = new_create_label
	$Box/Title.text = title
	$Box/Createrow/Create.text = create_label

## Materialize greys buttons out with GUI.enabled; this is the same thing.
func set_button_enabled(action: String, enabled: bool) -> void:
	(_buttons[action] as Button).disabled = not enabled

func _on_button(action: String) -> void:
	button_pressed.emit(action, map_type)

func _on_preview_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if _preview.texture == null:
		return
	var uv := click_uv(event.position, _preview.size, _preview.texture.get_size())
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
