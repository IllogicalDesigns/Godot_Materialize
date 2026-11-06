class_name MapModule
extends Node
## Base class for one texture map module: Height, Diffuse, Normal,
## Ambient Occlusion, Metallic, Smoothness.
##
## Each map lives in its own folder under `MapModules/` and owns everything
## that map needs: the generator (the pass driver), the shader, and the control
## panel. `MapModules/heightMap/` is the reference implementation.
##
## The app shell (`scenes/main.tscn` + `scripts/main.gd`) owns the shared state:
## the `Blit` framework, the source diffuse image, the map store, and the
## `MeshInstance3D` preview. A module never touches those directly. The contract
## is deliberately small, so a new map module can be added without touching the
## shell:
##
##   - `map_type()`, `map_title()`, `save_suffix()` identify the map.
##   - `settings()` returns the Dictionary the panel edits in place.
##   - `panel_scene()` is the panel that slots into `MapOptionsPanel`.
##   - `generate(source, blit)` runs the passes and returns the map.
##   - `preview(map)` prepares a map for on-screen display.
##   - `create_available(maps)` says whether the box's Create button can run.
##
## `settings_changed` fires when the panel edits a control; the shell debounces
## it and regenerates. `map_changed` fires when the map is updated. Colour
## picking is handled by the shell directly: the panel's `color_pick_requested`
## is connected to the shell, which owns the source image.

## Emitted when the panel changes a control, so the shell can regenerate.
signal settings_changed()
## Emitted when this map changes: the shell repaints the map box and the mesh.
signal map_changed(map_type: String, image: Image)

var map: Image

## Extra map inputs the shell hands to a tool that reads more than the map its
## `source_map_type()` picks. Normal From Height lights the surface from the
## pristine source for "Shape from Diffuse", so the shell passes the map store
## in before every generation. The reference is not copied.
var inputs: Dictionary = {}

func set_inputs(maps: Dictionary) -> void:
	inputs = maps

func map_type() -> String:
	push_error("%s does not implement map_type()" % name)
	return ""

func map_title() -> String:
	return map_type()

## The suffix Materialize appends to saved file names, e.g. "_height".
func save_suffix() -> String:
	return "_" + map_type()

## The settings Dictionary the panel edits. Must be the same Dictionary the
## generator reads, so panel edits reach the shader on the next pass.
func settings() -> Dictionary:
	push_error("%s does not implement settings()" % name)
	return {}

## The settings the panel's "Reset Parameters" button restores: the generator's
## `defaults()`. Each module overrides this with its own tool's defaults, e.g.
## `RoughnessFromDiffuse.defaults()`.
func default_settings() -> Dictionary:
	push_error("%s does not implement default_settings()" % name)
	return {}

## Restores the settings Dictionary to defaults, edited in place so the panel
## keeps the reference it edits. A fresh `defaults()` is written key by key:
## nested Dictionaries, Arrays, Color and Vector2 values are the new objects
## `defaults()` builds each call, so nothing is shared with the generator.
func reset_settings() -> void:
	var fresh: Dictionary = default_settings()
	var current: Dictionary = settings()
	for key: String in fresh:
		current[key] = fresh[key]

## The panel scene that slots into `MapOptionsPanel` while this map is active.
func panel_scene() -> PackedScene:
	push_error("%s does not implement panel_scene()" % name)
	return null

## Runs the map's passes. `source` is the map this tool reads (usually the
## diffuse), `blit` is the shared framework, already in the scene tree.
func generate(source: Image, blit: Blit) -> Image:
	push_error("%s does not implement generate()" % name)
	return null

## The map store key this tool reads as its input. Every tool works from the
## diffuse, so the base is "diffuse". The Diffuse tool is the exception: Unity's
## Edit Diffuse window reads `_DiffuseMapOriginal`, the pristine source, so its
## module returns "diffuse_original" and never sees its own output.
func source_map_type() -> String:
	return "diffuse"

## Whether this map's preview uses the split-screen reveal on the mesh (the
## Diffuse Reveal Slider, Materialize's `_Slider` in
## `Edit_Diffuse_Preview.shader`: source image on the left of the seam, edited
## map on the right). The Height Reveal Slider mixes towards grey instead, so
## the base says no.
func preview_split() -> bool:
	return false

## A copy of `map` prepared for display on the map box and the mesh. Modules
## override this when the raw map is not what the user should see. Preview-only
## controls (the height module's Height Reveal Slider) are not blended here:
## the shell applies them in the mesh preview material, so dragging them costs
## no pass.
func preview(map: Image) -> Image:
	return map

## Materialize greys out a box's Create button when its inputs are missing
## (`GUI.enabled` per button). The shell calls this with the map store.
func create_available(maps: Dictionary) -> bool:
	return map != null

## Stores a finished map and tells the shell about it.
func set_map(image: Image) -> void:
	map = image
	map_changed.emit(map_type(), image)

## Drops the map, matching Materialize's "Clear" button (and "Clear All
## Texture Maps", which clears every box).
func clear_map() -> void:
	set_map(null)