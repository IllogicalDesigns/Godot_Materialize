class_name NormalMapModule
extends MapModule
## The Normal map module: Materialize's Normal From Height tool, the third one
## ported, and the first tool that reads another generated map (the height map)
## instead of the source image.
##
## Everything Normal needs is in this folder:
##
##   normal_from_height.gd         the pass driver (settings, presets, generate)
##   normal_from_height.gdshader   BLUR / NORMAL / COMBINE passes
##   normal_panel.tscn + .gd       the tool panel, laid out like
##                                 NormalFromHeightGui.cs
##
## Materialize's box layout for Normal (`MainGui.cs` lines 660-779): box title
## "Normal Map", a 100x100 preview, P / C / O / S, Quick Save, Create, Clear.
## Create opens the Normal From Height window, which is what this module's
## panel stands in for.
##
## "Shape from Diffuse" reads the pristine source, so the module takes the map
## store through `set_inputs` (`MapModule`), the same way the shell reads its
## own map keys.

const PANEL_SCENE_PATH := "res://MapModules/normalMap/normal_panel.tscn"

var tool: NormalFromHeight

func _init() -> void:
	tool = NormalFromHeight.new()

func map_type() -> String:
	return "normal"

func map_title() -> String:
	return "Normal Map"

func settings() -> Dictionary:
	return tool.settings

## The Normal panel's "Reset Parameters" button restores Unity's
## `NormalFromHeightSettings` defaults.
func default_settings() -> Dictionary:
	return NormalFromHeight.defaults()

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## Normal From Height works from the height map (`MGS._HeightMap` in
## `NormalFromHeightGui.cs`), not the diffuse.
func source_map_type() -> String:
	return "height"

## Materialize enables the Normal box's Create only while a height map exists,
## and the "Shape from Diffuse" box only while a diffuse exists.
func create_available(maps: Dictionary) -> bool:
	return maps.get("height") != null

func generate(source: Image, blit: Blit) -> Image:
	# "Shape from Diffuse" lights the surface from the unedited source
	# (`_DiffuseMapOriginal`), not from the edited Diffuse map.
	var diffuse: Image = inputs.get("diffuse_original")
	var result := await tool.generate_from(source, blit, diffuse)
	set_map(result)
	return result

## No `preview()` override: the map's own colours are what the user wants to
## see, and the Normal Reveal Slider blends the shaded preview towards the raw
## colours in the mesh material (`shaders/mesh_preview.gdshader`), so dragging
## it costs no pass.
