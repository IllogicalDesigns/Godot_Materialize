extends Node

## Probe of `StandardMaterial3D`'s ambient occlusion properties: the port fills
## `ao_enabled` + `ao_texture` + `ao_texture_channel` on the full material, so
## the probe prints the AO property names this engine version has, the same way
## `tests/roughness_probe.gd` does for the roughness slot.

func _ready() -> void:
	var material := StandardMaterial3D.new()
	var names: Array = []
	for property in material.get_property_list():
		var key: String = property["name"]
		if key.contains("ao"):
			names.append(key)
	print("ao properties: ", names)
	print("TEXTURE_CHANNEL_RED: ", BaseMaterial3D.TEXTURE_CHANNEL_RED)
	get_tree().quit()
