shader_type canvas_item;

// Probe shader for the blit framework. Run with tests/blit_probe.tscn:
//   DISPLAY=:1 godot --path . res://tests/blit_probe.tscn
//
// pass 0 copies the source (readback path + format check),
// pass 1 writes a flat value,
// pass 2 writes an out-of-range value (HDR 2D readback check),
// pass 3 samples just off the left edge (repeat wrap check),
// pass 4 runs a 9-tap raised-cosine blur (loop + sampler behaviour check).

uniform sampler2D source : filter_linear, repeat_enable;
uniform highp vec2 texel = vec2(0.01, 0.01);
uniform highp int pass = 0;
uniform highp float value = 0.0;

void fragment() {
	if (pass == 1) {
		COLOR = vec4(value, value, value, 1.0);
	} else if (pass == 2) {
		COLOR = vec4(value, value * 0.5, 0.0, 1.0);
	} else if (pass == 3) {
		// Sample one pixel left of the edge: repeat wrapping should read the last column.
		COLOR = texture(source, vec2(-texel.x, 0.5));
	} else if (pass == 4) {
		// The pyramid blur kernel from shaders/height_from_diffuse.gdshader,
		// applied horizontally: pixel (1,0) should read the red marker.
		highp vec3 sum = vec3(0.0, 0.0, 0.0);
		highp float weight_sum = 0.0;
		for (int i = -4; i <= 4; i += 1) {
			highp float weight = cos(float(i) / 8.0 * TAU) * 0.5 + 0.5;
			sum += texture(source, SCREEN_UV + vec2(texel.x * float(i), 0.0)).rgb * weight;
			weight_sum += weight;
		}
		COLOR = vec4(sum / weight_sum, 1.0);
	} else {
		COLOR = texture(source, SCREEN_UV);
	}
}
