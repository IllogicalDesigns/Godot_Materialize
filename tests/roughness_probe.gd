extends Node

func _ready() -> void:
	var material := StandardMaterial3D.new()
	var names: Array = []
	for property in material.get_property_list():
		var key: String = property["name"]
		if key.contains("roughness"):
			names.append(key)
	print("roughness properties: ", names)
	print("TEXTURE_CHANNEL_RED: ", BaseMaterial3D.TEXTURE_CHANNEL_RED)
	get_tree().quit()
