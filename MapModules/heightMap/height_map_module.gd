class_name HeightMapModule
extends MapModule
## The Height map module: the first Materialize tool ported, and the reference
## for the other six map modules.
##
## Everything Height needs is in this folder:
##
##   height_from_diffuse.gd          the pass driver (settings, presets, generate)
##   height_from_diffuse.gdshader    SAMPLE / BLUR / COMBINE / AVG passes
##   height_panel.tscn + .gd         the tool panel, laid out like
##                                   HeightFromDiffuseGui.cs
##
## Materialize's box layout for Height (`MainGui.cs` lines 496-573): box title
## "Height Map", a 100x100 preview, P / C / O / S, Quick Save, Preview, Create,
## Clear. Create opens the Height From Diffuse window, which is what this
## module's panel stands in for.

const PANEL_SCENE_PATH := "res://MapModules/heightMap/height_panel.tscn"

var tool: HeightFromDiffuse

func _init() -> void:
	tool = HeightFromDiffuse.new()

func map_type() -> String:
	return "height"

func map_title() -> String:
	return "Height Map"

func settings() -> Dictionary:
	return tool.settings

## The Height panel's "Reset Parameters" button restores Unity's
## `HeightFromDiffuseSettings` defaults.
func default_settings() -> Dictionary:
	return HeightFromDiffuse.defaults()

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## Height is created from a diffuse source, so Create is available as soon as
## a diffuse map exists (Materialize also allows a normal map source, which
## comes with Normal From Height).
func create_available(maps: Dictionary) -> bool:
	return maps.get("diffuse") != null

func generate(source: Image, blit: Blit) -> Image:
	var result := await tool.generate(source, blit)
	set_map(result)
	return result

## No `preview()` override: the Height Reveal Slider ("Height Reveal Slider",
## `GuiHelper.cs` vertical slider, 0.5 default, not part of the saved settings)
## is a preview control, and the shell implements it in the mesh preview
## material (`shaders/mesh_preview.gdshader`), where the map is mixed towards
## mid-grey by `reveal` on the GPU. Changing it costs no pass, so dragging the
## slider updates the mesh every frame. The map itself is never blended.