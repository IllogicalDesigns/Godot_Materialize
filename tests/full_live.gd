extends Node
## Live test for "Show full Material": the default Godot material
## (`StandardMaterial3D`, the mesh's own material in `scenes/main.tscn`) filled
## from the map store - Diffuse in the Albedo slot, the Normal map in the Normal
## map slot, the Height map in the Heightmap slot, both features turned on,
## roughness as the shading control. Materialize's `SetMaterialValues` fills the
## Unity Standard material the same way (`MainGui.cs` lines 283-335); the port
## uses Godot's built-in material, so the shell writes slot textures and no
## shader is involved.
##
## Runs as the project's main scene under a display server
## (`DISPLAY=:1 godot --path . res://tests/full_live.tscn`) so the SubViewport
## renders and the GPU pass chains run. The phases follow the shell's status
## label, because a box's Create goes through the debounce:
## "ready" -> "Generating" -> "ready".
##
## Asserts:
##  - the shell loads with the full material assigned in the Inspector, the
##    normal and heightmap features on, roughness 0.6,
##  - Show full Material puts the full material on the mesh as
##    `material_override` and fills Albedo, Normal map and Heightmap from the
##    map store at the working size,
##  - the heightmap slot carries the height map's red channel, the channel
##    Godot's heightmap reads, so the generated relief is what parallax sees,
##  - the Albedo slot carries the Diffuse map, the Normal slot the generated
##    Normal map,
##  - Clear all texture maps empties the Normal and Heightmap slots and keeps
##    the source image in Albedo, the way Materialize's diffuse box falls back
##    to `_DiffuseMapOriginal` (`MainGui.cs` lines 293-299),
##  - a box's Preview button swaps the single-map preview material back onto the
##    mesh.
##
## Every widget the test drives is a shell `@export` reference, never a node
## path (`CODING_RULES.md`).

const SIZE := 512

const PHASE_START := 0
const PHASE_SIZE := 1
const PHASE_NORMAL := 2
const PHASE_SHOW := 3
const PHASE_CLEAR := 4
const PHASE_PREVIEW := 5

## 8-bit display rounding is exact on the channel copy, so the slot texture
## lands within one 8-bit step of the float map.
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
	if _frames > 1800:
		print("full live: timed out in phase ", _phase, ", status = ", _main._status.text)
		get_tree().quit()
		return
	match _phase:
		PHASE_START:
			var full: StandardMaterial3D = _main._full_material
			_check(full != null, "the full material is assigned in scenes/main.tscn")
			_check(full.normal_enabled, "the Normal map feature is turned on in the scene")
			_check(full.heightmap_enabled, "the Heightmap feature is turned on in the scene")
			_check(abs(full.roughness - 0.6) < 0.01,
					"roughness is the preview's 0.6, got %0.2f" % full.roughness)
			if not _main._status.text.contains("ready"):
				return
			# The shell starts at 1024. Drop to the size the test measures, so
			# the two chains run at their test cost.
			_main._resolution.select(0)
			_main._resolution.item_selected.emit(0)
			_phase = PHASE_SIZE
			print("full live: status '", _main._status.text, "', switching to ", SIZE)
		PHASE_SIZE:
			if not _main._status.text.contains("ready"):
				return
			var height: Image = _main.maps["height"]
			_check(height.get_size() == Vector2i(SIZE, SIZE),
					"the height map is ready at %d, got %s" % [SIZE, height.get_size()])
			# The normal map is the second slot to fill, so create it first.
			# Create activates the module and runs its chain.
			_main._on_box_button("create", "normal")
			_phase = PHASE_NORMAL
			print("full live: height ready, creating the normal map")
		PHASE_NORMAL:
			if not _main._status.text.contains("ready"):
				return
			var normal: Image = _main.maps["normal"]
			_check(normal.get_size() == Vector2i(SIZE, SIZE),
					"the normal map is ready at %d, got %s" % [SIZE, normal.get_size()])
			# Every slot has a map now, so Show full Material fills them all.
			_main._show_full_material_button.pressed.emit()
			_phase = PHASE_SHOW
			print("full live: normal ready, showing full material")
		PHASE_SHOW:
			var full2: StandardMaterial3D = _main._full_material
			_check(_main._status.text.contains("Showing full material"),
					"the status line reports the full material: %s" % [_main._status.text])
			_check(_main._mesh_map == "full",
					"the mesh map is the full material key, got %s" % [_main._mesh_map])
			_check(_main._mesh.material_override == full2,
					"the mesh material_override is the full material from the Inspector")
			var size := Vector2(SIZE, SIZE)
			_check(full2.albedo_texture != null and full2.albedo_texture.get_size() == size,
					"the Diffuse map fills the Albedo slot at %d, got %s"
					% [SIZE, full2.albedo_texture.get_size() if full2.albedo_texture != null else "null"])
			_check(full2.normal_texture != null and full2.normal_texture.get_size() == size,
					"the Normal map fills the Normal slot at %d, got %s"
					% [SIZE, full2.normal_texture.get_size() if full2.normal_texture != null else "null"])
			_check(full2.heightmap_texture != null and full2.heightmap_texture.get_size() == size,
					"the Height map fills the Heightmap slot at %d, got %s"
					% [SIZE, full2.heightmap_texture.get_size() if full2.heightmap_texture != null else "null"])
			if full2.heightmap_texture == null:
				_phase = PHASE_CLEAR
				_main._clear_all_maps_button.pressed.emit()
				print("full live: slots empty, clearing all maps")
				return
			# Godot's heightmap reads the red channel, and the height pass
			# writes its height there, so the slot must carry the relief.
			var center := Vector2i(SIZE / 2, SIZE / 2)
			var want: float = _main.maps["height"].get_pixelv(center).r
			var got: float = full2.heightmap_texture.get_image().get_pixelv(center).r
			print("full live: heightmap center red %.3f, height map red %.3f" % [got, want])
			_check(abs(got - want) < TOL,
					"the heightmap slot carries the height map, center %0.3f vs %0.3f" % [got, want])
			var albedo_mean := _mean(full2.albedo_texture.get_image())
			var diffuse_mean := _mean(_main.maps["diffuse"])
			print("full live: albedo mean %.3f, diffuse mean %.3f" % [albedo_mean, diffuse_mean])
			_check(abs(albedo_mean - diffuse_mean) < TOL,
					"the Albedo slot carries the Diffuse map, mean %0.3f vs %0.3f"
					% [albedo_mean, diffuse_mean])
			# The stone wall's normals lean out of straight up, so the normal
			# slot carries relief, not a flat map.
			var normal_mean_b := _channel(full2.normal_texture.get_image(), 2)
			var normal_tilt := _tilt(full2.normal_texture.get_image())
			print("full live: normal slot mean blue %.3f, tilt %.4f" % [normal_mean_b, normal_tilt])
			_check(normal_mean_b > 0.8 and normal_tilt > 0.05,
					"the Normal slot carries the generated relief, mean blue %0.3f, tilt %0.3f"
					% [normal_mean_b, normal_tilt])
			_phase = PHASE_CLEAR
			_main._clear_all_maps_button.pressed.emit()
			print("full live: slots filled, clearing all maps")
		PHASE_CLEAR:
			if not _main._status.text.contains("Cleared"):
				return
			var full3: StandardMaterial3D = _main._full_material
			_check(full3.normal_texture == null, "Clear all empties the Normal slot")
			_check(full3.heightmap_texture == null, "Clear all empties the Heightmap slot")
			# Unity's diffuse box falls back to `_DiffuseMapOriginal` when
			# `_DiffuseMap` is cleared, so the source stays in Albedo.
			_check(full3.albedo_texture != null
					and full3.albedo_texture.get_size() == Vector2(SIZE, SIZE),
					"the source image stays in the Albedo slot after a clear")
			_check(_main._mesh_map == "full",
					"the full material stays the mesh map after a clear, got %s" % [_main._mesh_map])
			# The Diffuse box's Preview button puts the single-map preview
			# material back on the mesh.
			(_main.boxes[1] as MapBox).preview_button.pressed.emit()
			_phase = PHASE_PREVIEW
			print("full live: cleared, previewing the diffuse box")
		PHASE_PREVIEW:
			_check(_main._mesh_map == "diffuse",
					"the box Preview button makes the diffuse map the mesh map again, got %s"
					% [_main._mesh_map])
			_check(_main._mesh.material_override == _main._mesh_material,
					"the mesh preview material is back on the mesh")
			if _failures.is_empty():
				print("full live: PASS")
			else:
				for failure in _failures:
					print("FAIL: %s" % failure)
				print("full live: FAIL")
			get_tree().quit()

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		print("FAIL: %s" % description)

func _mean(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			total += (color.r + color.g + color.b) / 3.0
	return total / float(image.get_size().x * image.get_size().y)

func _channel(image: Image, channel: int) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			total += color[channel]
	return total / float(image.get_size().x * image.get_size().y)

## The mean length of the red/green deviation from neutral 0.5: 0 on a flat
## normal map, above 0 when the normals lean, the same statistic
## `tests/normal_live.gd` measures.
func _tilt(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			total += sqrt((color.r - 0.5) * (color.r - 0.5) + (color.g - 0.5) * (color.g - 0.5))
	return total / float(image.get_size().x * image.get_size().y)