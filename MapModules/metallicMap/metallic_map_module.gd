class_name MetallicMapModule
extends MapModule
## The Metallic map module: Materialize's Metallic tool, the fourth one ported.
##
## Everything Metallic needs is in this folder:
##
##   metallic_from_diffuse.gd        the pass driver (settings, generate)
##   metallic_from_diffuse.gdshader  BLUR / METALLIC passes
##   metallic_panel.tscn + .gd       the tool panel, laid out like MetallicGui.cs
##
## Materialize's box layout for Metallic (`MainGui.cs` lines 747-820): box title
## "Metallic Map", a 100x100 preview, P / C / O / S, Quick Save, Create, Clear.
## Create opens the Metallic From Diffuse window, which is what this module's
## panel stands in for.
##
## The window's source row reads the edited Diffuse map for " Use Edited
## Diffuse" and the pristine source for " Use Original Diffuse", so the module
## takes the map store through `set_inputs` (`MapModule`), the same way Normal
## From Height reads the pristine source for "Shape from Diffuse".

const PANEL_SCENE_PATH := "res://MapModules/metallicMap/metallic_panel.tscn"

var tool: MetallicFromDiffuse

func _init() -> void:
	tool = MetallicFromDiffuse.new()

func map_type() -> String:
	return "metallic"

func map_title() -> String:
	return "Metallic Map"

func settings() -> Dictionary:
	return tool.settings

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## Metallic works from the diffuse, the map every other tool starts from
## (`_DiffuseMap` / `_DiffuseMapOriginal`), so the base "diffuse" source key is
## right, and the source row selects between the two inside the generator.
func create_available(maps: Dictionary) -> bool:
	# Unity enables the Metallic box's Create while either diffuse exists
	# (`MainGui.cs` line 808).
	return maps.get("diffuse") != null or maps.get("diffuse_original") != null

## Materialize's Metallic preview is a split: `Metallic_Preview.shader` lerps
## `_MainTex` (the diffuse) into the metallic mask at `_Slider` along UV.x
## (line 91), the same seam the Diffuse Reveal Slider draws.
func preview_split() -> bool:
	return true

func generate(source: Image, blit: Blit) -> Image:
	# " Use Original Diffuse" reads the unedited source
	# (`_DiffuseMapOriginal`), not the edited Diffuse map.
	var original: Image = inputs.get("diffuse_original")
	var result := await tool.generate(source, blit, tool.settings, original)
	set_map(result)
	return result

## No `preview()` override: the metallic mask is what the user wants to see, and
## the Metalic Reveal Slider moves the split seam in the mesh preview material
## (`shaders/mesh_preview.gdshader`), so dragging it costs no pass.
