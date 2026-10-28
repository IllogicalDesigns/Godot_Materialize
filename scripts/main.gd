extends Node3D
## Shell for the Godot port of Materialize (Unity sample project, Unity
## Technologies 2013, GPLv3). Materialize builds PBR texture maps from a source
## image using GPU "blit" passes. See README.md for the Unity -> Godot mapping
## and docs/how_materialize_works.md for the algorithm.
##
## The shell owns the shared state: the `Blit` framework, the map store
## (`maps`), the source diffuse, the map box row, the tool panel slot, and the
## 3D preview mesh. Every widget it wires is an `@export` assigned in
## `scenes/main.tscn`, so this script holds no node paths (`CODING_RULES.md`).
## Each texture map lives in its own module under `MapModules/` - see
## `MapModules/map_module.gd`. Height, Diffuse, Normal, Metallic, Roughness
## and AO are ported (`MapModules/heightMap/`, `MapModules/diffuseMap/`,
## `MapModules/normalMap/`, `MapModules/metallicMap/`,
## `MapModules/roughnessMap/`, `MapModules/aoMap/`); the rest are the roadmap
## rows in `MAP_BOXES`.
##
## Clicking a box's Create button makes that map active: its panel slots into
## `MapOptionsPanel`, its map feeds the `MeshInstance3D` preview, and the mesh
## updates live as the sliders move.
##
## "Show full Material" puts the default Godot material (`StandardMaterial3D`,
## the mesh's own material in `scenes/main.tscn`) on the mesh, filled straight
## from the map store: the Diffuse map in the Albedo slot, the Normal map in the
## Normal map slot, the Height map in the Heightmap slot, the Roughness map in
## the Roughness slot, the shading control, and the AO map in the Ambient
## Occlusion slot. The normal, heightmap and AO features are turned on as the
## maps arrive, so the built-in shader does the lighting and the shell only
## fills slots.
##
## The window is Materialize's layout (`MainGui.cs` lines 485-1288): the map box
## row, the saving options box, the 3D preview filling the rest of the window,
## and the view-button row under the boxes. Buttons that depend on unported
## tools report themselves in the status label.

const UNITY_SOURCE := "/home/tiny/AI/materialize/Materialize"

## Materialize's box row, in `MainGui.cs` draw order (lines 496-1050):
## Height, Diffuse, Normal, Metallic, Smoothness, AO, each a 110x250 box
## with a 100x100 preview. The Diffuse box's create button is labelled "Edit".
const MAP_BOXES: Array[Dictionary] = [
	{"type": "height", "title": "Height Map", "create": "Create",
		"unity": "Scripts/HeightFromDiffuseGui.cs + Shaders/Resources/Blit_Sample.shader",
		"module": "MapModules/heightMap/", "status": "ported (first tool)"},
	{"type": "diffuse", "title": "Diffuse Map", "create": "Edit",
		"unity": "Scripts/EditDiffuseGui.cs + Shaders/Resources/Blit_Shader.shader",
		"module": "MapModules/diffuseMap/", "status": "ported (second tool)"},
	{"type": "normal", "title": "Normal Map", "create": "Create",
		"unity": "Scripts/NormalFromHeightGui.cs + Shaders/Resources/Blit_Normal_From_Height.shader",
		"module": "MapModules/normalMap/", "status": "ported (third tool)"},
	{"type": "metallic", "title": "Metallic Map", "create": "Create",
		"unity": "Scripts/MetallicGui.cs + Shaders/Resources/Blit_Metallic.shader",
		"module": "MapModules/metallicMap/", "status": "ported (fourth tool)"},
	{"type": "roughness", "title": "Roughness Map", "create": "Create",
		"unity": "Scripts/SmoothnessGui.cs + Shaders/Resources/Blit_Smoothness.shader",
		"module": "MapModules/roughnessMap/", "status": "ported (fifth tool)"},
	{"type": "ao", "title": "AO Map", "create": "Create",
		"unity": "Scripts/AOFromNormalGui.cs + Shaders/AO_From_Normal_Preview.shader",
		"module": "MapModules/aoMap/", "status": "ported (sixth tool)"},
]

## The map boxes, in the same order as MAP_BOXES, assigned in the Inspector.
@export var boxes: Array[MapBox]

## The 3D preview mesh, the panel slot that the active module's panel goes
## into, the status label, the working resolution picker, and the dialogs.
@export var _mesh: MeshInstance3D
## The full material "Show full Material" puts on the mesh: the default Godot
## shader, `StandardMaterial3D`, assigned in `scenes/main.tscn` as the mesh's
## own material sub-resource. Albedo, Normal map and Heightmap slots are filled
## from the map store by `_fill_full_material()`.
@export var _full_material: StandardMaterial3D
@export var _panel_slot: VBoxContainer
## Hidden holder for the panels that are not on screen. The cached panels in
## `_panels` stay in the tree here, never freed, so switching back to a map
## finds the same valid panel with its slider state intact.
@export var _panel_park: VBoxContainer
@export var _status: Label
@export var _resolution: OptionButton
@export var _load_dialog: FileDialog
@export var _save_dialog: FileDialog
@export var _save_all_dialog: FileDialog
@export var _debounce: Timer
@export var _save_panel: PanelContainer

## The whole `UI` layer, which "Hide Gui" toggles.
@export var _ui: Control

## The toolbar, the view-button row, the corner buttons, and the Save panel's
## own widgets. Every one of them is assigned in `scenes/main.tscn`, so the
## shell wires its UI without a single node path (`CODING_RULES.md`).
@export var _load_diffuse_button: Button
@export var _stone_pattern_button: Button
@export var _generate_button: Button
@export var _save_map_button: Button
@export var _save_all_button: Button
@export var _save_format: OptionButton
@export var _show_full_material_button: Button
@export var _next_cube_map_button: Button
@export var _tile_maps_button: Button
@export var _clear_all_maps_button: Button
@export var _toggle_fullscreen_button: Button
@export var _quit_button: Button
@export var _make_suggestion_button: Button
@export var _hide_gui_button: Button

var blit: Blit

## The map store, the app's source of truth: map_type -> Image, null when empty.
## The source diffuse lives here too, so Materialize's rule that maps are
## derived from the loaded image holds, and "Clear" can free any map.
var maps: Dictionary = {}

## map_type -> MapModule, for the tools that are ported. Unported maps have no
## module, so their Create button is disabled.
var modules: Dictionary = {}

## map_type -> MapBox, and map_type -> panel, so each box's preview and panel
## can be refreshed without searching the tree.
var _boxes: Dictionary = {}
var _panels: Dictionary = {}

var _active: MapModule
var _mesh_map: String = ""
var _active_panel: Control
var _pick_sample := 0
var _busy := false
var _dirty := false
var _working_size := 1024
var _source_original: Image
var _save_type: String = ""
var _load_type: String = ""

## The 3D preview material (`shaders/mesh_preview.gdshader`): `map` is the
## previewed map, `reveal` is the Height Reveal Slider.
const MESH_SHADER_PATH := "res://shaders/mesh_preview.gdshader"

## The mesh map key "Show full Material" installs. It is not a map in the map
## store, so `_set_mesh_map` puts the full material on the mesh for this key.
const FULL_MESH_MAP := "full"

var _mesh_material: ShaderMaterial
## Flat grey texture used when a map is cleared, so the mesh does not go black.
var _neutral: ImageTexture

func _ready() -> void:
	_check_exports()

	# Report the roadmap to stdout so headless runs stay useful.
	for row in MAP_BOXES:
		print("[materialize] %s -> %s [%s]" % [row["unity"], row["module"], row["status"]])

	blit = Blit.new()
	add_child(blit)

	_mesh_material = ShaderMaterial.new()
	_mesh_material.shader = load(MESH_SHADER_PATH)
	_mesh_material.set_shader_parameter("roughness", 0.6)
	_neutral = _flat_texture(0.5)
	_mesh_material.set_shader_parameter("map", _neutral)
	_mesh_material.set_shader_parameter("reveal", 1.0)
	_mesh.material_override = _mesh_material

	for row in MAP_BOXES:
		maps[row["type"]] = null

	modules["height"] = _add_height_module()
	modules["diffuse"] = _add_diffuse_module()
	modules["normal"] = _add_normal_module()
	modules["metallic"] = _add_metallic_module()
	modules["roughness"] = _add_roughness_module()
	modules["ao"] = _add_ao_module()

	for index in MAP_BOXES.size():
		var spec: Dictionary = MAP_BOXES[index]
		var box: MapBox = boxes[index]
		box.map_type = spec["type"]
		box.title = spec["title"]
		box.create_label = spec["create"]
		# map_box.gd reads title and create_label in its _ready, which has
		# already run for the instanced boxes, so re-apply them here.
		box.set_labels(spec["title"], spec["create"])
		_boxes[spec["type"]] = box
		box.button_pressed.connect(_on_box_button)
		box.preview_clicked.connect(_on_preview_clicked)

	_refresh_box_buttons()

	_resolution.add_item("512", 512)
	_resolution.add_item("1024", 1024)
	_resolution.add_item("2048", 2048)
	_resolution.add_item("Source size", 0)
	_resolution.selected = 1
	_debounce.wait_time = 0.15

	_wire_ui()

	# Height is the only ported tool, so it is active from the start and its
	# panel is already in MapOptionsPanel.
	_activate(modules["height"])

	# The pass framework needs a real GPU: a headless run cannot render the
	# SubViewport quad, so headless stays a parse/import check with no passes.
	if DisplayServer.get_name() == "headless":
		_set_status("Headless run: the map modules are loaded, no GPU passes ran.")
		return

	# Start with the procedural stone wall so the mesh and the height map show
	# live output immediately, with no assets needed.
	_set_source(TestPattern.stone(Vector2i(_working_size, _working_size)))

## Wiring the buttons Materialize draws (`MainGui.cs`), so the scene stays free
## of connection blocks and every handler is visible in one place. The map box
## signals are wired per box in `_ready`.
func _wire_ui() -> void:
	_load_diffuse_button.pressed.connect(_on_load_pressed)
	_stone_pattern_button.pressed.connect(_on_pattern_pressed)
	_resolution.item_selected.connect(_on_resolution_selected)
	_generate_button.pressed.connect(_on_generate_pressed)
	_save_map_button.pressed.connect(_on_save_pressed)

	_save_all_button.pressed.connect(_on_save_all_pressed)

	_load_dialog.file_selected.connect(_on_load_file_selected)
	_save_dialog.file_selected.connect(_on_save_file_selected)
	_save_all_dialog.dir_selected.connect(_on_save_all_dir_selected)
	_debounce.timeout.connect(_on_debounce_timeout)

	_show_full_material_button.pressed.connect(_on_show_full_material_pressed)
	_next_cube_map_button.pressed.connect(_on_next_cube_map_pressed)
	_tile_maps_button.pressed.connect(_on_tile_maps_pressed)
	_clear_all_maps_button.pressed.connect(_on_clear_all_pressed)

	_toggle_fullscreen_button.pressed.connect(_on_fullscreen_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_make_suggestion_button.pressed.connect(_on_make_suggestion_pressed)
	_hide_gui_button.pressed.connect(_on_hide_gui_pressed)

func _add_height_module() -> MapModule:
	var module := HeightMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

func _add_diffuse_module() -> MapModule:
	var module := DiffuseMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

func _add_normal_module() -> MapModule:
	var module := NormalMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

func _add_metallic_module() -> MapModule:
	var module := MetallicMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

func _add_roughness_module() -> MapModule:
	var module := RoughnessMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

func _add_ao_module() -> MapModule:
	var module := AOMapModule.new()
	add_child(module)
	module.map_changed.connect(_on_map_changed)
	return module

## Make one map active: its panel goes into `MapOptionsPanel`, and its map goes
## onto the mesh. Panels are built once and reused, so slider state survives
## switching maps.
func _activate(module: MapModule) -> void:
	_active = module
	_mesh_map = module.map_type()

	var panel: Control = _panels.get(module.map_type())
	if panel == null:
		panel = module.panel_scene().instantiate()
		_panels[module.map_type()] = panel
		# The panel contract is setup() plus settings_changed / apply_requested /
		# color_pick_requested. The calls use the string API so the shell is not
		# typed to any one panel, and a new map module can add extra signals.
		panel.call("setup", module.settings())
		panel.connect("settings_changed", _on_settings_changed)
		panel.connect("apply_requested", _on_apply_requested)
		# Colour picking belongs to the panels that sample colours from the
		# source (Height's Color Samples), so the connection is guarded the same
		# way as the preview signal.
		if panel.has_signal("color_pick_requested"):
			panel.connect("color_pick_requested", _on_pick_requested)
		if panel.has_signal("preview_changed"):
			panel.connect("preview_changed", _on_preview_changed)

	# The panels are cached in `_panels` and reused, so the outgoing panel is
	# parked hidden in `_panel_park` and never freed. Freeing the slot's child
	# leaves a freed instance in `_panels`, and the next Create on that map
	# crashes assigning it ("Trying to assign invalid previously freed
	# instance"). `add_child` does not reparent: a parked panel must leave the
	# park before it comes back, and the outgoing panel must leave the slot
	# before it is parked. `remove_child` keeps every panel alive; `_panels`
	# holds the references across the moves, so no freed instance is assigned.
	if panel.get_parent() != null:
		panel.get_parent().remove_child(panel)
	if _active_panel != null and _active_panel != panel:
		_panel_slot.remove_child(_active_panel)
		_active_panel.visible = false
		_panel_park.add_child(_active_panel)
	_panel_slot.add_child(panel)
	panel.visible = true
	_active_panel = panel
	_set_mesh_map(_mesh_map)
	_set_reveal()

func _generate() -> void:
	if _busy:
		return
	if _active == null:
		_set_status("Pick a map box to work on.")
		return
	var source_key: String = _active.source_map_type()
	if maps.get(source_key) == null:
		_set_status("Load a diffuse image, or press the stone test pattern.")
		return

	_busy = true
	var source: Image = maps[source_key]
	var size := source.get_size()
	_set_status("Generating %d x %d..." % [size.x, size.y])

	# Tools that read more than their source map (Normal From Height reads the
	# pristine source for "Shape from Diffuse") get the map store before the
	# pass chain runs.
	_active.set_inputs(maps)
	await _active.generate(source, blit)

	_busy = false
	_set_status("%s ready: %d x %d" % [_active.map_title(), size.x, size.y])

	if _dirty:
		_dirty = false
		_generate()

## The module finished a pass chain. Repaint the box preview and, when the map
## is the one on the mesh, the mesh itself.
func _on_map_changed(map_type: String, image: Image) -> void:
	maps[map_type] = image
	var module: MapModule = modules.get(map_type)
	var display: Image = module.preview(image) if module != null else image
	if _boxes.has(map_type):
		(_boxes[map_type] as MapBox).set_image(display)
	if map_type == _mesh_map:
		_set_mesh_texture(display)
	if _mesh_map == FULL_MESH_MAP:
		# The full material shows every map at once, so any map change re-fills
		# its slot: a new height, normal, or diffuse map lands on the mesh
		# immediately, which is what Materialize's SetMaterialValues does for
		# the test object (`MainGui.cs` lines 283-335).
		_fill_full_material()
	_refresh_box_buttons()

func _set_mesh_texture(image: Image) -> void:
	if image == null:
		_mesh_material.set_shader_parameter("map", _neutral)
		return
	_mesh_material.set_shader_parameter("map", ImageTexture.create_from_image(Blit.to_display(image)))

## A 1x1 texture filled with one value. The mesh samples it when a map is
## cleared, so the preview stays neutral grey instead of going black on a null
## texture.
func _flat_texture(value: float) -> ImageTexture:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(value, value, value, 1.0))
	return ImageTexture.create_from_image(image)

## Which map the mesh shows. Materialize's "Preview" button applies a map to the
## test object, so the box's Preview button is what selects it.
func _set_mesh_map(map_type: String) -> void:
	_mesh_map = map_type
	if map_type == FULL_MESH_MAP:
		# "Show full Material": the built-in Godot material, filled from the
		# map store, goes on the mesh. The full material is the mesh's own
		# material in `scenes/main.tscn`, with the normal and heightmap
		# features switched on there, so the shell only fills slots.
		_mesh.material_override = _full_material
		_fill_full_material()
		return
	_mesh.material_override = _mesh_material
	# A normal map is tangent-space data, so the mesh shades it instead of
	# using it as albedo (`shaders/mesh_preview.gdshader` `is_normal`).
	_mesh_material.set_shader_parameter("is_normal", 1.0 if map_type == "normal" else 0.0)
	var module: MapModule = modules.get(map_type)
	var image: Image = maps.get(map_type)
	if image == null:
		_set_mesh_texture(null)
	else:
		_set_mesh_texture(module.preview(image) if module != null else image)

## "Show full Material" fills the built-in Godot material from the map store:
## the Diffuse map in the Albedo slot, the Normal map in the Normal map slot,
## the Height map in the Heightmap slot, the Roughness map in the Roughness
## slot, and the AO map in the Ambient Occlusion slot. Every slot is a plain
## 8-bit texture copy, so filling is a uniform write with no pass chain. Godot reads the heightmap from the red channel,
## which is where the height pass writes its height, and the normal map is
## stored signed (0.5 neutral), which is the tangent-space convention Godot
## samples. An empty map leaves its slot empty: StandardMaterial3D samples its
## built-in default for an empty slot, and the Albedo slot keeps the flat grey
## stand-in, the way Materialize writes `_TextureGrey` into `_DiffuseMap`
## (`MainGui.cs` lines 293-299).
func _fill_full_material() -> void:
	_full_material.albedo_texture = _display_texture(maps.get("diffuse"), _neutral)
	_full_material.normal_texture = _display_texture(maps.get("normal"))
	_full_material.heightmap_texture = _display_texture(maps.get("height"))
	# Roughness is the shading control the full material needs: the map is
	# greyscale, so the red channel carries it. Unity's test object puts its
	# smoothness map in the Standard shader's smoothness slot the same way
	# (`MainGui.cs` lines 283-335), and the port stores the inverted value, so
	# 0.0 in the map is a mirror, which is what the roughness slot wants.
	_full_material.roughness_texture = _display_texture(maps.get("roughness"))
	_full_material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	# AO is the Ambient Occlusion slot. Unity's AO preview
	# (`AO_From_Normal_Preview.shader`) multiplies the AO map into the lit
	# colour on the test object, which is what the engine's AO slot does, and
	# the combined map is greyscale, so the red channel carries it. The feature
	# flag is a property in this engine (`ao_enabled`), so the slot switches on
	# with the map and off when it is cleared, the way an empty slot samples the
	# material's default.
	var ao_map: Image = maps.get("ao")
	_full_material.ao_texture = _display_texture(ao_map)
	_full_material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	_full_material.ao_enabled = ao_map != null

## A map as an 8-bit texture for a material slot. `neutral` is the stand-in for
## a slot that needs one (Albedo); empty slots get null and sample the
## material's default.
func _display_texture(image: Image, neutral: ImageTexture = null) -> ImageTexture:
	if image == null:
		return neutral
	return ImageTexture.create_from_image(Blit.to_display(image))

## Sliders write into the module's settings Dictionary; debounce so dragging a
## fader does not fire a pass chain every 0.01.
func _on_settings_changed() -> void:
	_dirty = true
	_debounce.start()

func _on_debounce_timeout() -> void:
	if _busy:
		return
	if _dirty:
		_dirty = false
		_generate()

## The Height Reveal Slider is a preview control on the mesh material, so it is
## a uniform write: no pass, no CPU loop, and dragging it updates the mesh every
## frame. Materialize's `HFDS.Slider` is applied to the preview material the
## same way, and it is not part of the saved settings.
func _on_preview_changed() -> void:
	_set_reveal()

func _set_reveal() -> void:
	var reveal := 1.0
	var split := 0.0
	if _active != null:
		reveal = clampf(float(_active.settings().get("reveal", 1.0)), 0.0, 1.0)
		if _active.preview_split():
			split = reveal
	_mesh_material.set_shader_parameter("reveal", reveal)
	# Diffuse uses the split seam (`preview_split`); Height keeps the grey-mix
	# reveal, which is what `split_reveal` = 0 leaves in effect.
	_mesh_material.set_shader_parameter("split_reveal", split)

func _on_apply_requested() -> void:
	_dirty = false
	_generate()

func _on_box_button(action: String, map_type: String) -> void:
	var module: MapModule = modules.get(map_type)
	match action:
		"create":
			if module == null:
				_not_ported(map_type)
				return
			_activate(module)
			_generate()
		"preview":
			_set_mesh_map(map_type)
			_set_status("Showing %s on the mesh." % map_type)
		"clear":
			if module != null:
				module.clear_map()
			else:
				maps[map_type] = null
				_on_map_changed(map_type, null)
			if map_type == "diffuse":
				# Unity clears `_DiffuseMap` and the box falls back to
				# `_DiffuseMapOriginal` (`MainGui.cs` lines 574-670), so the
				# pristine source becomes the diffuse map again: the box and
				# the mesh both show the source, not the grey placeholder.
				maps["diffuse"] = maps["diffuse_original"]
				(_boxes["diffuse"] as MapBox).set_image(maps["diffuse"])
				if map_type == _mesh_map:
					_set_mesh_map(_mesh_map)
			elif map_type == _mesh_map:
				_set_mesh_texture(null)
		"open":
			_load_type = map_type
			_load_dialog.title = "Open %s" % (module.map_title() if module != null else map_type)
			_load_dialog.show()
		"save":
			if maps.get(map_type) == null:
				_set_status("Nothing to save for %s yet." % map_type)
				return
			_save_type = map_type
			_save_dialog.title = "Save %s" % (module.map_title() if module != null else map_type)
			_save_dialog.show()
		"quick_save":
			if maps.get(map_type) == null:
				_set_status("Nothing to quick save for %s yet." % map_type)
				return
			# Materialize quick-saves straight to `QuicksavePathProperty` with
			# the map's suffix (`MainGui.cs` lines 543-547); the port writes to
			# `user://` with the same suffix, no dialog.
			var suffix: String = module.save_suffix() if module != null else "_" + map_type
			var quick := Blit.to_display(maps[map_type])
			var quick_path := "user://materialize%s.png" % suffix
			if quick.save_png(quick_path) == OK:
				_set_status("Quick saved %s" % quick_path)
			else:
				_set_status("Quick save failed for %s." % map_type)
			_set_status("Clipboard is not ported yet (%s)." % map_type)
		_:
			_set_status("Unknown action %s." % action)

## Materialize greys out a box's Create button when its inputs are missing
## (`GUI.enabled`). Unported maps are disabled; ported maps check their inputs.
func _refresh_box_buttons() -> void:
	for row in MAP_BOXES:
		var map_type: String = row["type"]
		var box: MapBox = _boxes[map_type]
		var module: MapModule = modules.get(map_type)
		box.set_button_enabled("create", module != null and module.create_available(maps))
		box.set_button_enabled("save", maps.get(map_type) != null)
		box.set_button_enabled("clear", maps.get(map_type) != null)
		box.set_button_enabled("preview", maps.get(map_type) != null)
		box.set_button_enabled("quick_save", maps.get(map_type) != null)
		box.set_button_enabled("paste", false)
		box.set_button_enabled("copy", false)

func _not_ported(map_type: String) -> void:
	for row in MAP_BOXES:
		if row["type"] == map_type:
			_set_status("%s is not ported yet: %s" % [map_type, row["unity"]])
			return

## The status label is mirrored to stdout, so a headless run and a run from a
## terminal report what the pass pipeline is doing. Materialize's window has no
## status line, so both the label and the print are port-only aids.
func _set_status(text: String) -> void:
	_status.text = text
	print("[materialize] ", text)

## The panel asked for a colour from the source. Materialize raycasts the 3D
## test mesh for this; here the click comes from the Diffuse box's preview,
## which forwards the UV inside the drawn image.
func _on_pick_requested(sample_index: int) -> void:
	_pick_sample = sample_index
	_set_status("Click the colour in the Diffuse preview for sample %d." % sample_index)

func _on_preview_clicked(map_type: String, uv: Vector2) -> void:
	if _pick_sample == 0:
		return
	if map_type != "diffuse":
		_set_status("Colour picking reads the Diffuse preview.")
		return
	var source: Image = maps["diffuse"]
	if source == null:
		return
	var size := source.get_size()
	var x := clampi(int(uv.x * float(size.x)), 0, size.x - 1)
	var y := clampi(int(uv.y * float(size.y)), 0, size.y - 1)
	var picked: Color = source.get_pixel(x, y)
	var sample_index := _pick_sample
	_pick_sample = 0
	var panel: Control = _panels[_active.map_type()]
	if panel.has_method("set_sample_color"):
		panel.call("set_sample_color", sample_index, picked)
	_generate()

## original: the image as loaded (8-bit), or a procedurally generated float
## image. The working copy is derived from it, so resolution changes re-derive
## instead of compounding resizes.
##
## The working copy lives in two map keys, the way Materialize keeps the source
## image: `maps["diffuse_original"]` is the pristine source that the Diffuse
## tool reads (`_DiffuseMapOriginal`), and `maps["diffuse"]` is the map every
## other tool reads, starting as a copy of the source. The Diffuse box shows
## `maps["diffuse"]` falling back to the source, like Unity's box draws
## `_DiffuseMap` and falls back to `_DiffuseMapOriginal` (`MainGui.cs`
## lines 574-670).
func _set_source(original: Image) -> void:
	_source_original = original
	var working := original.duplicate()
	if _working_size > 0:
		working.resize(_working_size, _working_size, Image.INTERPOLATE_CUBIC)
	var source := Blit.to_float(working)
	maps["diffuse_original"] = source
	# The Diffuse box shows the source copy, the way Unity copies the loaded
	# image into `_DiffuseMap` and the box draws `_DiffuseMap` while editing.
	_mesh_material.set_shader_parameter("original", ImageTexture.create_from_image(Blit.to_display(source)))
	var diffuse: MapModule = modules.get("diffuse")
	if diffuse != null:
		diffuse.set_map(source.duplicate())
	else:
		maps["diffuse"] = source
	_generate()

func _on_load_pressed() -> void:
	_load_type = "diffuse"
	_load_dialog.title = "Load a diffuse image"
	_load_dialog.show()

func _on_load_file_selected(path: String) -> void:
	var image: Image = Image.load_from_file(path)
	if image == null:
		_set_status("Could not load %s" % path)
		return
	if _load_type == "diffuse":
		_set_source(image)
		return
	# Opening a map into a box stores it as that map, so it can be previewed and
	# used as a pass input later. The map store is float everywhere, so the
	# loaded image goes through `to_float` before it is stored.
	var working: Image = Blit.to_float(image)
	_on_map_changed(_load_type, working)

func _on_pattern_pressed() -> void:
	var size := _working_size if _working_size > 0 else 1024
	_set_source(TestPattern.stone(Vector2i(size, size)))

func _on_resolution_selected(index: int) -> void:
	_working_size = _resolution.get_item_id(index)
	if _source_original != null:
		_set_source(_source_original)

func _on_generate_pressed() -> void:
	_dirty = false
	_generate()

func _on_save_pressed() -> void:
	if maps.get(_mesh_map) == null:
		_set_status("Nothing to save yet.")
		return
	_save_type = _mesh_map
	_save_dialog.show()

func _on_save_file_selected(path: String) -> void:
	var image: Image = maps.get(_save_type)
	if image == null:
		_set_status("Nothing to save for %s." % _save_type)
		return
	var display := Blit.to_display(image)
	var error := display.save_png(path)
	if error == OK:
		_set_status("Saved %s" % path)
	else:
		_set_status("Save failed: %s (%s)" % [path, error_string(error)])

## Save all maps: the format comes from the Save panel, and each map is written
## as `materialize_<map>` with Materialize's suffix, e.g. `materialize_height.png`.
func _on_save_all_pressed() -> void:
	var empty := true
	for map_type: String in maps:
		if maps[map_type] != null:
			empty = false
	if empty:
		_set_status("No maps to save.")
		return
	_save_all_dialog.show()

func _on_save_all_dir_selected(path: String) -> void:
	var format_id := _save_format.get_selected_id()
	var extension: String = ["bmp", "jpg", "png", "tga", "tiff"][format_id]
	# Godot writes PNG, JPG and WebP. BMP, TGA and TIFF need a custom writer
	# (`MainGui.cs` used FreeImage.dll), so the port writes PNG and says so.
	if extension in ["bmp", "tga", "tiff"]:
		_set_status("%s export is not written yet, saving PNG." % extension)
		extension = "png"

	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK:
		_set_status("Could not create %s (%s)" % [path, error_string(error)])
		return

	var written := 0
	for row in MAP_BOXES:
		var map_type: String = row["type"]
		var image: Image = maps[map_type]
		if image == null:
			continue
		var display := Blit.to_display(image)
		var file := "%s/%s_%s.%s" % [path, "materialize", map_type, extension]
		if extension == "jpg":
			error = display.save_jpg(file)
		else:
			error = display.save_png(file)
		if error != OK:
			_set_status("Save failed: %s (%s)" % [file, error_string(error)])
			return
		written += 1
	_set_status("Saved %d maps into %s" % [written, path])

func _on_show_full_material_pressed() -> void:
	# Materialize's ShowFullMaterial closes the tool windows and puts the full
	# PBR material on the test object (`MainGui.cs` lines 419-424,
	# `MaterialGui.cs` `Initialize`). The port fills the built-in Godot material
	# from the map store and puts it on the mesh; the panels stay open, which is
	# the port's deviation.
	_set_mesh_map(FULL_MESH_MAP)
	_set_status("Showing full material on the mesh: Diffuse in Albedo, Normal map, Heightmap, Roughness map, AO map.")

func _on_next_cube_map_pressed() -> void:
	_set_status("Cube maps are not ported yet (Assets/CubeMaps).")

func _on_tile_maps_pressed() -> void:
	_set_status("Seamless tiling is not ported yet (Blit_Seamless_Texture_Maker.shader).")

func _on_clear_all_pressed() -> void:
	for map_type: String in maps:
		if map_type == "diffuse_original":
			continue
		maps[map_type] = null
	for module: MapModule in modules.values():
		module.clear_map()
	for box: MapBox in _boxes.values():
		box.set_image(null)
	# Unity's ClearAllTextureMaps clears `_DiffuseMap`, and the Diffuse box
	# falls back to `_DiffuseMapOriginal` (`MainGui.cs` lines 574-670), so the
	# box and the split-screen preview show the source image again.
	var source: Image = maps["diffuse_original"]
	if source != null:
		maps["diffuse"] = source
		var diffuse: MapModule = modules.get("diffuse")
		if diffuse != null:
			diffuse.map = source
		(_boxes["diffuse"] as MapBox).set_image(source)
		_set_mesh_map(_mesh_map)
	else:
		_set_mesh_texture(null)
	_set_status("Cleared all texture maps.")

func _on_hide_gui_pressed() -> void:
	_ui.visible = not _ui.visible

func _on_make_suggestion_pressed() -> void:
	_set_status("Suggestions go to the Materialize forum; this port has no mail window.")

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_fullscreen_pressed() -> void:
	# Materialize's button label swaps between "Windowed" and "Full Screen"
	# (`MainGui.cs` lines 451-461), same rect.
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_toggle_fullscreen_button.text = "Windowed"
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_toggle_fullscreen_button.text = "Full Screen"

## Reports exports that were never assigned in the Inspector, so a missing
## widget shows up as an error at load instead of a null crash mid-run.
func _check_exports() -> void:
	for name: String in ["boxes", "_mesh", "_full_material", "_panel_slot", "_panel_park", "_status", "_resolution",
			"_load_dialog", "_save_dialog", "_save_all_dialog", "_debounce",
			"_save_panel", "_ui", "_load_diffuse_button", "_stone_pattern_button",
			"_generate_button", "_save_map_button", "_save_all_button", "_save_format",
			"_show_full_material_button", "_next_cube_map_button", "_tile_maps_button",
			"_clear_all_maps_button", "_toggle_fullscreen_button", "_quit_button",
			"_make_suggestion_button", "_hide_gui_button"]:
		if get(name) == null:
			push_error("main.gd export %s is not assigned in scenes/main.tscn" % name)
	if boxes.size() != MAP_BOXES.size():
		push_error("main.gd boxes has %d entries, MAP_BOXES has %d"
			% [boxes.size(), MAP_BOXES.size()])
