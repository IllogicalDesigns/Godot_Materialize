shader_type canvas_item;

uniform sampler2D source : filter_linear, repeat_enable;
// The swatch as a plain vec4, with no colour semantics.
uniform highp vec4 as_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform highp vec4 as_vector = vec4(0.0, 0.0, 0.0, 1.0);
uniform highp int mode = 0;

void fragment() {
	if (mode == 9) { COLOR = vec4(as_color); }
	else if (mode == 10) { COLOR = vec4(as_vector); }
	else { COLOR = vec4(texture(source, SCREEN_UV).rgb, 1.0); }
}
