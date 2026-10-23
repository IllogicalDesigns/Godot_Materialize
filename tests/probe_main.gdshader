shader_type canvas_item;
uniform sampler2D source : filter_linear, repeat_enable;
uniform highp int pass = 5;
uniform highp float probe_x = 0.0;
uniform highp float probe_y = 0.0;
void fragment() {
	if (pass == 5) {
		COLOR = vec4(texture(source, SCREEN_UV).rgb, 1.0);
	}
}
