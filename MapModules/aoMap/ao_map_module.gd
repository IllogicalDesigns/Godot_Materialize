class_name AOMapModule
extends MapModule
## The AO map module: Materialize's Normal + Depth to AO tool, the sixth one
## ported.
##
## Everything AO needs is in this folder:
##
##   ao_from_normal.gd        the pass driver (settings, generate)
##   ao_from_normal.gdshader  AO / COMBINE passes
##   ao_panel.tscn + .gd      the tool panel, laid out like AOFromNormalGui.cs
##
## Materialize's box layout for AO (`MainGui.cs` lines 976-1049): box title
## "AO Map", a 100x100 preview, P / C / O / S, Quick Save, Create, Clear.
## Create opens the "Normal + Depth to AO" window, which is what this module's
## panel stands in for.
##
## AO is the one tool that does not read the diffuse: the pass reads the
## Normal map, Unity's `_MainTex` on the AO blit (`AOFromNormalGui.cs` line
## 323), and the Height map for the depth term, Unity's `_HeightTex`
## (`_HDHeightMap` first, then `_HeightMap`, lines 304-310). So the module's
## source key is "normal" and the Height map rides in through `set_inputs`
## (`MapModule`), the same way Metallic and Roughness read the Metallic map.
##
## Unity enables the box's Create when a Normal map exists, a Height map
## exists, or both (`MainGui.cs` line 1034), and runs on flat default textures
## when a map is missing (`InitializeTextures` lines 215-221, the blit
## fallbacks lines 301, 309). The port gates Create on the Normal map alone:
## the shell runs every tool from its `source_map_type()` map, so a
## height-only Create has no source map to run from, documented deviation.

const PANEL_SCENE_PATH := "res://MapModules/aoMap/ao_panel.tscn"

var tool: AOFromNormal

func _init() -> void:
	tool = AOFromNormal.new()

func map_type() -> String:
	return "ao"

func map_title() -> String:
	return "AO Map"

func settings() -> Dictionary:
	return tool.settings

## The AO panel's "Reset Parameters" button restores Unity's
## `AOFromNormalSettings` defaults.
func default_settings() -> Dictionary:
	return AOFromNormal.defaults()

func panel_scene() -> PackedScene:
	return load(PANEL_SCENE_PATH)

## The map this tool reads is the Normal map, Unity's `_NormalMap` on the AO
## blit line (`AOFromNormalGui.cs` line 323), not the diffuse.
func source_map_type() -> String:
	return "normal"

func create_available(maps: Dictionary) -> bool:
	return maps.get("normal") != null

func generate(source: Image, blit: Blit) -> Image:
	# The depth term reads the Height map (`_HeightTex`); Unity takes
	# `_HDHeightMap` first and `_HeightMap` second, the port has one height.
	var height: Image = inputs.get("height")
	var result := await tool.generate(source, blit, height, tool.settings)
	set_map(result)
	return result

## No `preview()` override: the AO map is what the user wants to see, and
## Unity's AO preview (`AO_From_Normal_Preview.shader`) has no reveal seam, so
## `preview_split()` stays at the base false and the panel has no Reveal Slider.
