extends Node

## Probe the AO pass chain: print the accumulator and combine output at
## a small size, sweeping the settings.

var _blit: Blit

func _ready() -> void:
	_blit = Blit.new()
	add_child(_blit)
	await _run()
	get_tree().quit()

func _run() -> void:
	var size := Vector2i(16, 16)
	var stone: Image = TestPattern.stone(size)
	var height: Image = await HeightFromDiffuse.new().generate(stone, _blit)
	var normal: Image = await NormalFromHeight.new().generate(height, _blit)
	print("height mean %.3f, normal mean %.3f" % [_mean(height), _mean(normal)])

	var driver := AOFromNormal.new()
	var params := {"passes": 20, "ao_samples": 10}
	for blend in [1.0, 0.0]:
		for spread in [50.0, 100.0, 10.0]:
			var p := params.duplicate()
			p["blend"] = blend
			p["spread"] = spread
			var ao: Image = await driver.generate(normal, _blit, height, p)
			print("blend %.1f spread %.0f -> AO mean %.3f" % [blend, spread, _mean(ao)])

func _mean(img: Image) -> float:
	var total: float = 0.0
	for y in img.get_height():
		for x in img.get_width():
			total += img.get_pixel(x, y).r
	return total / float(img.get_width() * img.get_height())
