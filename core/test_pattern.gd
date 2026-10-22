class_name TestPattern
extends RefCounted
## Built-in procedural diffuse source, so the tool can be exercised without
## importing any assets. A stone wall with mortar joints, per-brick colour
## variation, bevel shading at the joints, fine grain, and a global lighting
## gradient from the top.
##
## The wall is a good Height From Diffuse test: the joints give sharp local
## relief, the grain gives fine detail, and the top-down gradient is exactly
## the kind of slow luminance ramp that the average-subtraction step is
## supposed to discard. Everything is deterministic for a given seed.

## size: working resolution. seed: pattern variation.
static func stone(size: Vector2i, seed_value: int = 1337) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)

	# Eight bricks across the width keeps the pattern legible at any size.
	var brick_width := maxf(float(size.x) / 8.0, 16.0)
	var brick_height := maxf(float(size.y) / 12.0, 12.0)
	var mortar := clampf(brick_width * 0.07, 2.0, 12.0)

	var grain := FastNoiseLite.new()
	grain.seed = seed_value
	grain.frequency = 24.0 / float(size.x)
	grain.fractal_octaves = 3

	var blocks := FastNoiseLite.new()
	blocks.seed = seed_value + 1
	blocks.frequency = 1.0 / float(size.x)

	for y in range(size.y):
		var row := int(float(y) / brick_height)
		# Running bond: odd rows are offset by half a brick.
		var row_offset := brick_width * 0.5 if (row % 2 == 1) else 0.0
		var light := 1.0 - 0.3 * (float(y) / float(size.y))

		for x in range(size.x):
			var local_x := fmod(float(x) + row_offset, brick_width)
			var local_y := fmod(float(y), brick_height)
			var in_mortar := local_x < mortar or local_y < mortar

			var value := 0.0
			if in_mortar:
				# Mortar is dark and slightly rough.
				value = 0.32 + grain.get_noise_2d(float(x), float(y)) * 0.06
			else:
				# One flat base tone per brick, picked from the block noise.
				var brick_x := int((float(x) + row_offset) / brick_width)
				var tone := 0.58 + blocks.get_noise_2d(float(brick_x * 1000), float(row * 1000)) * 0.16
				# Bevel: darken the first few pixels next to the joint.
				var edge := minf(minf(local_x - mortar, brick_width - mortar - local_x),
						minf(local_y - mortar, brick_height - mortar - local_y))
				var bevel := clampf(edge / (brick_width * 0.08), 0.0, 1.0)
				value = tone * (0.72 + 0.28 * bevel)
				value += grain.get_noise_2d(float(x), float(y)) * 0.05

			value *= light
			value = clampf(value, 0.0, 1.0)
			# A faint warm cast keeps the source looking like a real photo.
			image.set_pixel(x, y, Color(value * 1.06, value * 1.0, value * 0.92, 1.0))

	return image
