class_name RoughnessMapModule
extends MapModule
## The Roughness map module: Materialize's Smoothness tool, the fifth one
## ported.
##
## Everything Roughness needs is in this folder:
##
##   roughness_from_diffuse.gd        the pass driver (settings, generate)
##   roughness_from_diffuse.gdshader  BLUR / ROUGHNESS passes
##   roughness_panel.tscn + .gd       the tool panel, laid out like SmoothnessGui.cs
##
## Materialize's box layout for Smoothness (`MainGui.cs` lines 825-899): box
## title "Smoothness Map", a 100x100 preview, P / C / O / S, Quick Save, Create,
## Clear. Create opens the Smoothness From Diffuse window, which is what this
## module's panel stands in for.
##
## The port's box is named for what it stores: Unity numbers are smoothness
## (1.0 = mirror), the map is roughness (0.0 = mirror), so it lands in the
## `StandardMaterial3D.roughness_texture` slot of "Show full Material" with no
## extra inversion.
##
## The window's source row reads the edited Diffuse map for " Use Edited
## Diffuse" and the pristine source for " Use Original Diffuse", and the metal
## level reads the Metallic map, so the module takes the map store through
## `set_inputs` (`MapModule`), the same way Metallic and Normal From Height do.

const PANEL_SCENE_PATH := "res://MapModules/roughnessMap/roughness_panel.tscn"

var tool: RoughnessFromDiffuse

func _init() -> void:
	tool = RoughnessFromDiffuse.new()

func map_type() -> String:
	return "roughness"

func map_title() -> String:
	return "Roughness Map"

func settings() -> Dictionary:
	return tool.settings

## The Roughness panel's "Reset Parameters" button restores Unity's
## `SmoothnessSettings` defaults.
func default_settings() -> Dictionary:
	return RoughnessFromDiffuse.defaults()

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## Roughness works from the diffuse, the map every other tool starts from
## (`_DiffuseMap` / `_DiffuseMapOriginal`), so the base "diffuse" source key is
## right, and the source row selects between the two inside the generator.
## Unity enables the Smoothness box's Create while a diffuse exists
## (`MainGui.cs` line 869).
func create_available(maps: Dictionary) -> bool:
	return maps.get("diffuse") != null or maps.get("diffuse_original") != null

## Materialize's Smoothness preview is a split: `Smoothness_Preview.shader`
## lerps the diffuse into the smoothness map at `_Slider` along UV.x, the same
## seam the Diffuse and Metallic Reveal Sliders draw.
func preview_split() -> bool:
	return true

func generate(source: Image, blit: Blit) -> Image:
	# " Use Original Diffuse" reads the unedited source
	# (`_DiffuseMapOriginal`), not the edited Diffuse map, and "Metal Smoothness"
	# reads the Metallic map (`_MetallicTex`).
	var original: Image = inputs.get("diffuse_original")
	var metallic: Image = inputs.get("metallic")
	var result := await tool.generate(source, blit, original, metallic, tool.settings)
	set_map(result)
	return result

## No `preview()` override: the roughness map is what the user wants to see, and
## the Smoothness Reveal Slider moves the split seam in the mesh preview material
## (`shaders/mesh_preview.gdshader`), so dragging it costs no pass.
