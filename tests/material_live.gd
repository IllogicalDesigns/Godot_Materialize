extends Node
## Live test for the Save panel's "Save Material" button: every map in the map
## store is written into the chosen folder as `materialize_<map>.<ext>`, and the
## Godot material built from them is written as `materialize_material.res`.
## Materialize exports the maps with their suffixes (`MainGui.cs` lines
## 543-547) and keeps the material live on the test object
## (`MainGui.cs` lines 283-335); the port exports both, so the folder is the
## deliverable.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/material_live.tscn`) so the
## SubViewport renders and the GPU pass chains run. The phases follow the
## shell's status label, because a Create goes through a chain:
## "ready" -> "Generating" -> "ready".
##
## Asserts:
##  - the Save panel carries the Save Material button, wired as a shell export
##    and sharing the Save panel's folder dialog,
##  - the button arms the dialog for the material export, the format picker's
##    unwritable formats (TGA here) fall back to PNG, the same rule Save all
##    maps uses, and the dialog flag clears after the write,
##  - every map lands in the folder at the working size, with Materialize's
##    `materialize_<map>` naming, and the pristine source is not exported,
##  - `materialize_material.res` loads back as a `StandardMaterial3D` with
##    Albedo, Normal, Heightmap, Roughness, Metallic and AO slots carrying the
##    maps: size, red-channel packing, the feature flags, and the slot values
##    matching the maps they were built from,
##  - `heightmap_scale` is Materialize's height slider default, 0.5, and the
##    shading controls ride at 1.0, so the exported map drives its slot without
##    the preview's 0.6 multiplier,
##  - a material export after Clear all texture maps keeps the source in Albedo,
##    leaves the empty slots empty, switches the AO and Normal features off, and
##    writes no file for a cleared map,
##  - Save all maps keeps the same folder picker for a maps-only export and
##    writes no material file, so the two Save panel buttons do not interfere.
##
## Every widget the test drives is a shell `@export` reference, never a node
## path (`CODING_RULES.md`).

const SIZE := 512

## The material file the shell writes, mirroring `main.gd`'s `MATERIAL_FILE`.
const MATERIAL_FILE := "materialize_material.res"

## The brick brown a "Pick Color" click on the wall finds, so Metallic scores the
## wall as metal and Roughness' metal regions lift smoothness off base, the same
## setting `tests/roughness_live.gd` drives.
const BRICK := Color(0.45, 0.22, 0.17)

## The folders the test writes into. `user://` is the test's write access, the
## same place the Quick Save checks write to.
const FOLDER := "user://material_live"
const PARTIAL_FOLDER := "user://material_live_partial"
const MAPS_ONLY_FOLDER := "user://material_live_maps_only"

const MAP_TYPES: Array[String] = ["height", "diffuse", "normal", "metallic", "roughness", "ao"]

const PHASE_START := 0
const PHASE_SHOT := 1
const PHASE_SIZE := 2
const PHASE_METALLIC := 3
const PHASE_METALLIC_READY := 4
const PHASE_NORMAL := 5
const PHASE_ROUGHNESS := 6
const PHASE_AO := 7
const PHASE_SAVE := 8
const PHASE_LOAD := 9
const PHASE_CLEAR := 10
const PHASE_PARTIAL := 11
const PHASE_SAVE_ALL := 12

## 8-bit display rounding is exact on the channel copy, so the slot texture
## lands within one 8-bit step of the float map, the same tolerance
## `tests/full_live.gd` uses.
const TOL := 0.02

var _frames := 0
var _phase := PHASE_START
var _main: Node
var _failures: Array[String] = []

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	_frames += 1
	if _frames > 3600:
		print("material live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			var button: Button = _main._save_material_button
			_check(button != null, "the Save Material button is assigned in scenes/main.tscn")
			_check(button.text.contains("Material"),
					"the button says Save Material, got %s" % [button.text])
			_check(_main._save_all_dialog.dir_selected.is_connected(
					_main._on_save_all_dir_selected),
					"the Save Material button shares the Save panel's folder dialog")
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the size the live tests measure,
			# so the chains run at their test cost.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SHOT
			print("material live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SHOT:
			if not _main._status.text.contains("ready"):
				return
			# A window screenshot for the eye, so the new Save panel button is
			# inspectable: `user://material_live_window.png`.
			var screenshot: Image = get_tree().root.get_texture().get_image()
			screenshot.save_png("user://material_live_window.png")
			print("material live: wrote user://material_live_window.png")
			_phase = PHASE_SIZE
			var height: Image = _main.maps["height"]
			_check(height.get_size() == Vector2i(SIZE, SIZE),
					"the height map is ready at %d, got %s" % [SIZE, height.get_size()])
			# Metallic, Roughness and AO feed the material's slots, so build them
			# in the order the tools read: Metallic first, then the Normal map,
			# then Roughness, which reads the metallic map, then AO from the
			# normal map.
			_main._activate(_main.modules["metallic"])
			var panel: Control = _main._panel_slot.get_child(0) as Control
			panel.metal_color_picker.color = BRICK
			panel.weight_faders[0].slider.value = 1.0
			panel.weight_faders[1].slider.value = 0.0
			panel.weight_faders[2].slider.value = 0.0
			panel.weight_faders[3].slider.value = 0.0
			panel.weight_faders[4].slider.value = 0.5
			_main.boxes[3].create_button.pressed.emit()
			_phase = PHASE_METALLIC
			print("material live: Metallic window on the brick colour, Low 0.0 High 0.5")
		PHASE_METALLIC:
			if _main._status.text.contains("Generating"):
				_phase = PHASE_METALLIC_READY
		PHASE_METALLIC_READY:
			if not _main._status.text.contains("ready"):
				return
			var metal: Image = _main.maps["metallic"]
			_check(metal != null and metal.get_size() == Vector2i(SIZE, SIZE),
					"the metallic map is %d x %d, got %s"
					% [SIZE, SIZE, metal.get_size() if metal != null else Vector2i()])
			var metal_mean := _channel(metal, 0)
			print("material live: metallic mean %.3f, wall colour scores as metal" % metal_mean)
			_check(metal_mean > 0.5,
					"the metallic map is mostly metal on the wall, mean %0.3f" % metal_mean)
			_main._on_box_button("create", "normal")
			_phase = PHASE_NORMAL
			print("material live: metallic ready, creating the normal map")
		PHASE_NORMAL:
			if not _main._status.text.contains("ready"):
				return
			var normal: Image = _main.maps["normal"]
			_check(normal.get_size() == Vector2i(SIZE, SIZE),
					"the normal map is ready at %d, got %s" % [SIZE, normal.get_size()])
			_main._on_box_button("create", "roughness")
			_phase = PHASE_ROUGHNESS
			print("material live: normal ready, creating the roughness map")
		PHASE_ROUGHNESS:
			if not _main._status.text.contains("ready"):
				return
			var rough: Image = _main.maps["roughness"]
			_check(rough.get_size() == Vector2i(SIZE, SIZE),
					"the roughness map is ready at %d, got %s" % [SIZE, rough.get_size()])
			_main._on_box_button("create", "ao")
			_phase = PHASE_AO
			print("material live: roughness ready, creating the AO map")
		PHASE_AO:
			if not _main._status.text.contains("ready"):
				return
			var ao: Image = _main.maps["ao"]
			_check(ao != null and ao.get_size() == Vector2i(SIZE, SIZE),
					"the AO map is ready at %d, got %s" % [SIZE, ao.get_size() if ao != null else Vector2i()])
			# Every slot has a map, so press the Save panel's button. TGA is the
			# format the port cannot write, so the status note comes first, then
			# the folder picks the export destination.
			_main._save_format.select(3)
			_main._save_material_button.pressed.emit()
			_check(_main._save_material,
					"the button arms the shared folder dialog for the material export")
			_check(_main._save_all_dialog.title == "Save Material Folder",
					"the button opens the folder dialog for the material export")
			_check(_main._save_all_dialog.visible,
					"the dialog is Godot's own FileDialog, on screen")
			_check(_main._save_all_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR,
					"the folder dialog is in folder mode, so dir_selected can fire")
			_main._save_all_dialog.dir_selected.emit(FOLDER)
			_phase = PHASE_SAVE
			print("material live: every map ready, TGA format, saving into ", FOLDER)
		PHASE_SAVE:
			_check(_main._status.text.contains("maps and the material"),
					"the status reports a material export: %s" % [_main._status.text])
			var access := DirAccess.open(FOLDER)
			_check(access != null, "the export folder exists at %s" % [FOLDER])
			if access == null:
				_phase = PHASE_CLEAR
				_main._clear_all_maps_button.pressed.emit()
				print("material live: no folder, clearing all maps")
				return
			for map_type: String in MAP_TYPES:
				var file := "%s/materialize_%s.png" % [FOLDER, map_type]
				_check(access.file_exists(file),
						"the %s map is written with Materialize's naming, missing %s" % [map_type, file])
				_check(not access.file_exists("%s/materialize_%s.tga" % [FOLDER, map_type]),
						"TGA falls back to PNG, the way Save all maps does, no %s.tga" % map_type)
			_check(access.file_exists(FOLDER + "/" + MATERIAL_FILE),
					"the material file is written, missing %s/%s" % [FOLDER, MATERIAL_FILE])
			_check(not access.file_exists(FOLDER + "/materialize_diffuse_original.png"),
					"the pristine source is not a map, so it is not exported")
			_check(_main._save_material == false,
					"the dialog flag clears after the export, so Save all maps stays maps-only")
			_phase = PHASE_LOAD
			print("material live: maps and material written, loading the material back")
		PHASE_LOAD:
			var material: StandardMaterial3D = ResourceLoader.load(
					FOLDER + "/" + MATERIAL_FILE, "", ResourceLoader.CACHE_MODE_IGNORE)
			_check(material != null, "the material file loads back as a resource")
			if material == null:
				_phase = PHASE_CLEAR
				_main._clear_all_maps_button.pressed.emit()
				print("material live: material unreadable, clearing all maps")
				return
			var size := Vector2i(SIZE, SIZE)
			for slot: Array in [["Albedo", material.albedo_texture, "diffuse"],
					["Normal", material.normal_texture, "normal"],
					["Heightmap", material.heightmap_texture, "height"],
					["Roughness", material.roughness_texture, "roughness"],
					["Metallic", material.metallic_texture, "metallic"],
					["AO", material.ao_texture, "ao"]]:
				var texture: ImageTexture = slot[1]
				_check(texture != null,
						"the %s slot carries the %s map" % [slot[0], slot[2]])
				if texture != null:
					_check(Vector2i(texture.get_size()) == size,
							"the %s slot texture is the %s map at %d, got %s"
							% [slot[0], slot[2], SIZE, Vector2i(texture.get_size())])
			_check(material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED,
					"the Roughness slot reads the map's red channel, got %d"
					% [material.roughness_texture_channel])
			_check(material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED,
					"the Metallic slot reads the map's red channel, got %d"
					% [material.metallic_texture_channel])
			_check(material.ao_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED,
					"the AO slot reads the map's red channel, got %d"
					% [material.ao_texture_channel])
			_check(material.normal_enabled, "the exported material turns the Normal map feature on")
			_check(material.heightmap_enabled, "the exported material turns the Heightmap feature on")
			_check(material.ao_enabled, "the exported material turns the AO feature on")
			_check(abs(material.heightmap_scale - 0.5) < 0.01,
					"the heightmap scale is Materialize's 0.5 slider default, got %0.2f"
					% material.heightmap_scale)
			_check(abs(material.roughness - 1.0) < 0.01,
					"the Roughness slot map drives shading at base 1.0, got %0.2f" % material.roughness)
			_check(abs(material.metallic - 1.0) < 0.01,
					"the Metallic slot map drives shading at base 1.0, got %0.2f" % material.metallic)
			# The slots carry the maps they were built from, so the export is what
			# the preview showed: the wall's colour in Albedo, the generated
			# relief in the Normal slot, the height relief in the Heightmap slot's
			# red channel.
			var albedo_mean := _mean_rgb(material.albedo_texture.get_image())
			var diffuse_mean := _mean_rgb(_main.maps["diffuse"])
			print("material live: albedo mean %.3f, diffuse mean %.3f" % [albedo_mean, diffuse_mean])
			_check(abs(albedo_mean - diffuse_mean) < TOL,
					"the Albedo slot carries the Diffuse map, mean %0.3f vs %0.3f"
					% [albedo_mean, diffuse_mean])
			var normal_tilt := _tilt(material.normal_texture.get_image())
			var normal_mean_b := _channel(material.normal_texture.get_image(), 2)
			print("material live: normal slot mean blue %.3f, tilt %.4f" % [normal_mean_b, normal_tilt])
			_check(normal_mean_b > 0.8 and normal_tilt > 0.05,
					"the Normal slot carries the generated relief, mean blue %0.3f, tilt %0.3f"
					% [normal_mean_b, normal_tilt])
			var center := Vector2i(SIZE / 2, SIZE / 2)
			var want: float = _main.maps["height"].get_pixelv(center).r
			var got: float = material.heightmap_texture.get_image().get_pixelv(center).r
			print("material live: heightmap center red %.3f, height map red %.3f" % [got, want])
			_check(abs(got - want) < TOL,
					"the Heightmap slot carries the height map's red channel, center %0.3f vs %0.3f"
					% [got, want])
			var rough_mean := _channel(material.roughness_texture.get_image(), 0)
			var rough_map_mean := _channel(_main.maps["roughness"], 0)
			print("material live: roughness slot mean %.3f, roughness map mean %.3f"
					% [rough_mean, rough_map_mean])
			_check(abs(rough_mean - rough_map_mean) < TOL,
					"the Roughness slot carries the roughness map, mean %0.3f vs %0.3f"
					% [rough_mean, rough_map_mean])
			var metal_slot_mean := _channel(material.metallic_texture.get_image(), 0)
			var metal_map_mean := _channel(_main.maps["metallic"], 0)
			print("material live: metallic slot mean %.3f, metallic map mean %.3f"
					% [metal_slot_mean, metal_map_mean])
			_check(abs(metal_slot_mean - metal_map_mean) < TOL,
					"the Metallic slot carries the metallic map, mean %0.3f vs %0.3f"
					% [metal_slot_mean, metal_map_mean])
			var ao_slot_mean := _channel(material.ao_texture.get_image(), 0)
			var ao_map_mean := _channel(_main.maps["ao"], 0)
			print("material live: AO slot mean %.3f, AO map mean %.3f" % [ao_slot_mean, ao_map_mean])
			_check(abs(ao_slot_mean - ao_map_mean) < TOL,
					"the AO slot carries the AO map, mean %0.3f vs %0.3f" % [ao_slot_mean, ao_map_mean])
			_phase = PHASE_CLEAR
			_main._clear_all_maps_button.pressed.emit()
			print("material live: material verified, clearing all maps")
		PHASE_CLEAR:
			if not _main._status.text.contains("Cleared"):
				return
			# Unity's diffuse box falls back to `_DiffuseMapOriginal` on a clear
			# (`MainGui.cs` lines 574-670), so a cleared store exports the one map
			# it has: the source stays in Albedo, the empty slots stay empty, and
			# the features switch with their maps.
			_main._save_material_button.pressed.emit()
			_check(_main._save_all_dialog.title == "Save Material Folder",
					"a cleared store still exports the source, so the dialog opens")
			_check(_main._save_all_dialog.visible,
					"the dialog is Godot's own FileDialog, on screen")
			_main._save_all_dialog.dir_selected.emit(PARTIAL_FOLDER)
			_phase = PHASE_PARTIAL
			print("material live: cleared, exporting the partial store")
		PHASE_PARTIAL:
			_check(_main._status.text.contains("1 maps and the material"),
					"the partial export reports one map: %s" % [_main._status.text])
			var material2: StandardMaterial3D = ResourceLoader.load(
					PARTIAL_FOLDER + "/" + MATERIAL_FILE, "", ResourceLoader.CACHE_MODE_IGNORE)
			_check(material2 != null, "the partial material file loads back")
			if material2 == null:
				_phase = PHASE_SAVE_ALL
				_main._save_format.select(2)
				_main._save_all_button.pressed.emit()
				_main._save_all_dialog.dir_selected.emit(MAPS_ONLY_FOLDER)
				print("material live: partial material unreadable, saving maps only")
				return
			_check(material2.albedo_texture != null
					and Vector2i(material2.albedo_texture.get_size()) == Vector2i(SIZE, SIZE),
					"the source image stays in the Albedo slot after a clear")
			_check(material2.normal_texture == null, "Clear all empties the Normal slot in the export")
			_check(material2.heightmap_texture == null, "Clear all empties the Heightmap slot in the export")
			_check(material2.roughness_texture == null, "Clear all empties the Roughness slot in the export")
			_check(material2.metallic_texture == null, "Clear all empties the Metallic slot in the export")
			_check(material2.ao_texture == null, "Clear all empties the AO slot in the export")
			_check(not material2.ao_enabled, "the AO feature switches off with the cleared AO map")
			_check(not material2.normal_enabled, "the Normal feature switches off with the cleared normal map")
			var access2 := DirAccess.open(PARTIAL_FOLDER)
			_check(access2 != null and access2.file_exists(PARTIAL_FOLDER + "/materialize_diffuse.png"),
					"the partial folder carries the one map the store has")
			_check(access2 != null and not access2.file_exists(PARTIAL_FOLDER + "/materialize_height.png"),
					"the partial folder writes no file for a cleared map")
			# Save all maps keeps the same folder picker for a maps-only export,
			# so the two buttons do not interfere.
			_main._save_format.select(2)
			_main._save_all_button.pressed.emit()
			_main._save_all_dialog.dir_selected.emit(MAPS_ONLY_FOLDER)
			_phase = PHASE_SAVE_ALL
			print("material live: partial export verified, Save all maps into ", MAPS_ONLY_FOLDER)
		PHASE_SAVE_ALL:
			_check(_main._status.text.contains("maps into"),
					"Save all maps keeps its own status line: %s" % [_main._status.text])
			var access3 := DirAccess.open(MAPS_ONLY_FOLDER)
			_check(access3 != null, "the maps-only folder exists")
			if access3 != null:
				_check(not access3.file_exists(MAPS_ONLY_FOLDER + "/" + MATERIAL_FILE),
						"Save all maps writes no material file")
			if _failures.is_empty():
				print("material live: PASS")
			else:
				for failure in _failures:
					print("FAIL: %s" % failure)
				print("material live: FAIL")
			get_tree().quit()

func _mean_rgb(image: Image) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			total += (color.r + color.g + color.b) / 3.0
	return total / float(image.get_width() * image.get_height())

func _channel(image: Image, channel: int) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			total += image.get_pixel(x, y)[channel]
	return total / float(image.get_width() * image.get_height())

## The mean length of the red/green deviation from neutral 0.5: 0 on a flat
## normal map, above 0 when the normals lean, the same statistic
## `tests/full_live.gd` and `tests/normal_live.gd` measure.
func _tilt(image: Image) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			total += sqrt((color.r - 0.5) * (color.r - 0.5) + (color.g - 0.5) * (color.g - 0.5))
	return total / float(image.get_width() * image.get_height())

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		print("FAIL: %s" % description)
