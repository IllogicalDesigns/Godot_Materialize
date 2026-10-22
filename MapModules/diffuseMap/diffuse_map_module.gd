class_name DiffuseMapModule
extends MapModule
## The Diffuse map module: Materialize's "Edit Diffuse" tool, the second tool
## ported.
##
## Everything Diffuse needs is in this folder:
##
##   edit_diffuse.gd           the pass driver (settings, generate)
##   edit_diffuse.gdshader     BLUR / EDIT passes
##   diffuse_panel.tscn + .gd  the tool panel, laid like EditDiffuseGui.cs
##
## Materialize's box layout for Diffuse (`MainGui.cs` lines 574-670): box title
## "Diffuse Map", a 100x100 preview, P / O buttons, Quick Save, Create labelled
## "Edit", Clear. The box shows `_DiffuseMap`, falling back to
## `_DiffuseMapOriginal` when nothing has been edited, and its P / O buttons
## target the original, so the shell keeps the pristine source in
## `maps["diffuse_original"]` and the edited output in `maps["diffuse"]`.

const PANEL_SCENE_PATH := "res://MapModules/diffuseMap/diffuse_panel.tscn"

var tool: DiffuseGenerator

func _init() -> void:
	tool = DiffuseGenerator.new()

func map_type() -> String:
	return "diffuse"

func map_title() -> String:
	return "Diffuse Map"

func settings() -> Dictionary:
	return tool.settings

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## The Diffuse tool reads the pristine source, Unity's `_DiffuseMapOriginal`,
## so it gets the untouched working copy from the shell, not the edited map.
func source_map_type() -> String:
	return "diffuse_original"

## The Diffuse Reveal Slider splits the mesh preview at the seam: left of the
## seam the source image, right of the seam the edited map, exactly Unity's
## `_Slider` in `Edit_Diffuse_Preview.shader`. The shell applies it in the mesh
## preview material, so dragging it costs no pass.
func preview_split() -> bool:
	return true

## Editing the diffuse needs only the source image, so "Edit" is available as
## soon as a source is loaded.
func create_available(maps: Dictionary) -> bool:
	return maps.get("diffuse_original") != null

func generate(source: Image, blit: Blit) -> Image:
	var result := await tool.generate(source, blit)
	set_map(result)
	return result
