extends Control
## Skeleton shell for the Godot port of Materialize.
##
## Materialize is a Unity sample project (Unity Technologies, 2013, GPLv3) that
## builds PBR texture maps from a source image using GPU "blit" passes:
## height, normal, edge, AO, metallic, smoothness, seamless tiling, plus a
## material preview and export path. This project rebuilds it in Godot.
##
## Nothing has been ported yet. This scene is only a shell that lists the tools
## we intend to port, so the project runs and shows the roadmap. See README.md
## for the Unity -> Godot mapping and the porting order.

const UNITY_SOURCE := "/home/tiny/AI/materialize/Materialize"

## One row per Unity tool panel, in the order we plan to port it.
## `status` is updated as each tool is ported.
const GENERATORS: Array[Dictionary] = [
	{
		"tool": "Height From Diffuse",
		"unity": "Scripts/HeightFromDiffuseGui.cs + Shaders/Resources/Blit_Height_From_Diffuse.shader",
		"target": "core/height_from_diffuse.gd + shaders/height_from_diffuse.gdshader",
		"status": "not started",
	},
	{
		"tool": "Normal From Height",
		"unity": "Scripts/NormalFromHeightGui.cs + Shaders/Resources/Blit_Normal_From_Height.shader",
		"target": "core/normal_from_height.gd + shaders/normal_from_height.gdshader",
		"status": "not started",
	},
	{
		"tool": "Edge From Normal",
		"unity": "Scripts/EdgeFromNormalGui.cs + Shaders/Resources/Blit_Edge_From_Normal.shader",
		"target": "core/edge_from_normal.gd + shaders/edge_from_normal.gdshader",
		"status": "not started",
	},
	{
		"tool": "AO From Normal",
		"unity": "Scripts/AOFromNormalGui.cs + Shaders/AO_From_Normal_Preview.shader",
		"target": "core/ao_from_normal.gd + shaders/ao_from_normal.gdshader",
		"status": "not started",
	},
	{
		"tool": "Metallic",
		"unity": "Scripts/MetallicGui.cs + Shaders/Resources/Blit_Metallic.shader",
		"target": "core/metallic.gd + shaders/metallic.gdshader",
		"status": "not started",
	},
	{
		"tool": "Smoothness",
		"unity": "Scripts/SmoothnessGui.cs + Shaders/Resources/Blit_Smoothness.shader",
		"target": "core/smoothness.gd + shaders/smoothness.gdshader",
		"status": "not started",
	},
	{
		"tool": "Edit Diffuse",
		"unity": "Scripts/EditDiffuseGui.cs + Shaders/Edit_Diffuse_Preview.shader",
		"target": "core/edit_diffuse.gd + shaders/edit_diffuse.gdshader",
		"status": "not started",
	},
	{
		"tool": "Alignment",
		"unity": "Scripts/AlignmentGui.cs + Shaders/Resources/Blit_Alignment.shader",
		"target": "core/alignment.gd + shaders/alignment.gdshader",
		"status": "not started",
	},
	{
		"tool": "Seamless Tiling",
		"unity": "Scripts/TilingTextureMakerGui.cs + Shaders/Resources/Blit_Seamless_Texture_Maker.shader",
		"target": "core/seamless_tiling.gd + shaders/seamless_tiling.gdshader",
		"status": "not started",
	},
	{
		"tool": "Post Process",
		"unity": "PostProcess/PostProcess.cs + PostProcess/Resources/HiddenPostProcess.shader",
		"target": "core/post_process.gd + shaders/post_process.gdshader",
		"status": "not started",
	},
	{
		"tool": "Material Preview (DNMST)",
		"unity": "Scripts/MaterialGui.cs + Shaders/DNMST.shader",
		"target": "core/material_preview.gd + shaders/dnmst.gdshader",
		"status": "not started",
	},
	{
		"tool": "Save / Load Project",
		"unity": "Scripts/SaveLoadProject.cs",
		"target": "core/project_io.gd",
		"status": "not started",
	},
]

@onready var _grid: GridContainer = $VBox/Grid

func _ready() -> void:
	$VBox/SubTitle.text = "Source: %s (Unity 2017 project, GPLv3)\nNothing ported yet - see README.md." % UNITY_SOURCE

	for row in GENERATORS:
		_add_row(row["tool"], row["unity"], row["target"], row["status"])

	# Report the roadmap to stdout so headless runs are useful too.
	for row in GENERATORS:
		print("[skeleton] %s -> %s [%s]" % [row["tool"], row["target"], row["status"]])

func _add_row(tool: String, unity_path: String, target: String, status: String) -> void:
	_grid.add_child(_label(tool))
	_grid.add_child(_label(unity_path))
	_grid.add_child(_label(target))
	_grid.add_child(_label(status))

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
