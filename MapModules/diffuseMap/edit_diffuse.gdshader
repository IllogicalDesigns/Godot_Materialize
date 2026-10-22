shader_type canvas_item;

// Diffuse map tool, ported from Materialize's
// Assets/Shaders/Resources/Blit_Shader.shader (passes 1 and 11).
//
// One shader holds the passes of the tool, and the GDScript driver picks one
// with the `pass` uniform - exactly like Unity picked a SubShader pass:
//
//   pass 1 BLUR - one separable axis of the raised-cosine blur, used for the
//                 overlay blur and the average colour map
//   pass 2 EDIT - fragEditDiffuse: spot removal, lighting removal, overlay,
//                 colour restore, contrast / bias, saturation
//
// Data space: raw 0..1 file values (display-referred) stored in float
// textures, the same space the Height tool works in.

const int PASS_BLUR = 1;
const int PASS_EDIT = 2;

// Materialize's luminance weights, not the standard 0.299 / 0.587 / 0.114.
const vec3 GREY = vec3(0.3, 0.5, 0.2);

// Taps on each side of the centre for one blur axis. The window is gated by
// the blur size, so taps past the active radius are skipped.
const int BLUR_MAX = 100;

uniform sampler2D source : filter_linear, repeat_enable;
// The overlay blur and the average colour map, Materialize's _BlurTex and
// _AvgTex, supplied by the driver as extra samplers on the edit pass.
uniform sampler2D blur_map : filter_linear, repeat_enable;
uniform sampler2D avg_map : filter_linear, repeat_enable;

uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 1;

// --- Blur pass ---------------------------------------------------------------

uniform highp vec2 direction = vec2(1.0, 0.0);
uniform highp float blur_size = 20.0;

// --- Edit pass ---------------------------------------------------------------

// Hot / dark spot removal, light / dark masks, and their powers. These are the
// slider values themselves; the powers are remapped in the shader, exactly as
// fragEditDiffuse does, so the driver passes the slider straight through.
uniform highp float hot_spot = 0.0;
uniform highp float dark_spot = 0.0;
uniform highp float light_mask_pow = 0.5;
uniform highp float dark_mask_pow = 0.5;
uniform highp float light_pow = 0.0;
uniform highp float dark_pow = 0.0;
uniform highp float blur_contrast = 0.0;
uniform highp float color_lerp = 0.5;
uniform highp float final_contrast = 1.0;
uniform highp float final_bias = 0.0;
uniform highp float saturation = 1.0;

float saturate(highp float value) {
	return clamp(value, 0.0, 1.0);
}

// Ported from Assets/Shaders/Resources/Photoshop.cginc, the same HSL maths the
// Height tool's shader uses.
vec3 rgb_to_hsl(vec3 color) {
	highp float fmin = min(min(color.r, color.g), color.b);
	highp float fmax = max(max(color.r, color.g), color.b);
	highp float delta = fmax - fmin;
	highp vec3 hsl = vec3(0.0, 0.0, (fmax + fmin) * 0.5);

	if (delta == 0.0) {
		return hsl; // Achromatic: hue and saturation stay 0.
	}

	if (hsl.z < 0.5) {
		hsl.y = delta / (fmax + fmin);
	} else {
		hsl.y = delta / (2.0 - fmax - fmin);
	}

	highp float delta_r = (((fmax - color.r) / 6.0) + (delta * 0.5)) / delta;
	highp float delta_g = (((fmax - color.g) / 6.0) + (delta * 0.5)) / delta;
	highp float delta_b = (((fmax - color.b) / 6.0) + (delta * 0.5)) / delta;

	if (color.r == fmax) {
		hsl.x = delta_b - delta_g;
	} else if (color.g == fmax) {
		hsl.x = (1.0 / 3.0) + delta_r - delta_b;
	} else if (color.b == fmax) {
		hsl.x = (2.0 / 3.0) + delta_g - delta_r;
	}

	if (hsl.x < 0.0) {
		hsl.x += 1.0;
	} else if (hsl.x > 1.0) {
		hsl.x -= 1.0;
	}

	return hsl;
}

float hue_to_rgb(highp float left, highp float right, highp float value) {
	value = value > 6.0 ? value - 6.0 : value;
	value = value < 0.0 ? value + 6.0 : value;
	value = value > 4.0 ? 1.0 - value * 0.25 : value < 1.0 ? value : 1.0;
	return mix(left, right, value);
}

vec3 hsl_to_rgb(vec3 hsl) {
	highp vec3 result = vec3(hsl.z, hsl.z, hsl.z);
	if (hsl.y > 0.0) {
		highp float right = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
		highp float left = 2.0 * hsl.z - right;
		result.r = hue_to_rgb(left, right, hsl.x * 6.0 + 2.0);
		result.g = hue_to_rgb(left, right, hsl.x * 6.0);
		result.b = hue_to_rgb(left, right, hsl.x * 6.0 - 2.0);
	}
	return result;
}

void fragment() {
	if (pass == PASS_BLUR) {
		// Raised-cosine windowed blur along one axis: Materialize's fragBlur.
		// Unity stacked many narrow passes; one pass with the full radius and
		// the raised-cosine window lands the same spread in a single frame.
		highp vec2 uv = SCREEN_UV;
		highp vec3 sum = vec3(0.0, 0.0, 0.0);
		highp float weight_sum = 0.0;
		highp float radius = max(blur_size, 1.0);

		for (int i = -BLUR_MAX; i <= BLUR_MAX; i += 1) {
			if (abs(i) > int(radius)) {
				continue;
			}
			highp float weight = cos(float(i) / radius * PI) * 0.5 + 0.5;
			sum += texture(source, uv + direction * texel * float(i)).rgb * weight;
			weight_sum += weight;
		}

		COLOR = vec4(sum / max(weight_sum, 0.0001), 1.0);
	} else {
		// fragEditDiffuse, Blit_Shader pass 11, in order.
		highp vec3 main_tex = texture(source, SCREEN_UV).rgb;
		highp vec3 blur_tex = texture(blur_map, SCREEN_UV).rgb;
		highp vec3 avg_color = texture(avg_map, SCREEN_UV).rgb;

		// overlay
		highp vec3 overlay = main_tex - blur_tex;

		// save original copy
		highp vec3 initial_hsl = rgb_to_hsl(main_tex);

		// spot removal
		highp float avg_lum = dot(main_tex, GREY);
		highp float light_mask = smoothstep(1.0 - hot_spot,
				(1.0 - hot_spot) + pow(max(hot_spot, 0.0), 0.5) + 0.01, avg_lum);
		highp float dark_mask = smoothstep(dark_spot - pow(max(dark_spot, 0.0), 0.5) - 0.01,
				dark_spot, avg_lum); // this mask is inverted
		main_tex = mix(main_tex, avg_color, 1.0 - (1.0 - light_mask) * dark_mask);

		// Lighting removal
		highp float light_pow_p = saturate((light_mask_pow - 0.5) * 2.0) + 1.0;
		light_pow_p -= 1.0 - (1.0 / (saturate((light_mask_pow - 0.5) * -2.0) + 1.0));

		highp float dark_pow_p = saturate((dark_mask_pow - 0.5) * 2.0) + 1.0;
		dark_pow_p -= 1.0 - (1.0 / (saturate((dark_mask_pow - 0.5) * -2.0) + 1.0));

		main_tex -= avg_color;
		highp float grey = dot(main_tex, GREY);
		// Unity broadcasts the scalar mask across the channels (`half3
		// mainTexHighMask = pow(...) scalar`), which Godot's shading language
		// spells out as a vec3 fill.
		highp vec3 high_mask = vec3(pow(clamp(grey * 2.0, 0.001, 0.99), light_pow_p));
		highp vec3 low_mask = vec3(pow(clamp(-grey * 2.0, 0.001, 0.99), dark_pow_p));
		main_tex += 0.5;

		main_tex = mix(main_tex, main_tex * (1.0 - light_pow), high_mask);
		main_tex = mix(main_tex, 1.0 - (1.0 - main_tex) * (1.0 - dark_pow), low_mask);

		// Unity stores the masks as `half3` broadcast from scalar masks and
		// converts back to float for desaturate (`half3 * float` to float).
		// Godot spells the broadcast and the channel read out; the channels
		// are equal, so `.r` is Unity's implicit float.
		highp float desaturate_mask = high_mask.r * light_pow;
		desaturate_mask += low_mask.r * dark_pow * 2.0;
		desaturate_mask += 1.0 - (1.0 - light_mask) * dark_mask;
		desaturate_mask = 1.0 - saturate(desaturate_mask);

		// apply overlay
		highp float overlay_mask = 1.0 - (1.0 - high_mask.r * light_pow)
				* (1.0 - low_mask.r * dark_pow);
		overlay_mask = saturate(overlay_mask * 2.0 + 0.1);
		main_tex *= mix(vec3(1.0), overlay * blur_contrast * 10.0 + 1.0, overlay_mask);
		main_tex = clamp(main_tex, vec3(0.0), vec3(1.0));

		// maintain color
		highp vec3 hsl = rgb_to_hsl(clamp(main_tex, vec3(0.0), vec3(1.0)));
		hsl.xy = initial_hsl.xy;
		highp vec3 original_color = hsl_to_rgb(hsl);
		main_tex = mix(main_tex, original_color, color_lerp * desaturate_mask);

		// brightness and contrast
		main_tex = clamp((main_tex - 0.5) * final_contrast + 0.5 + final_bias,
				vec3(0.0), vec3(1.0));

		// Saturation
		main_tex = mix(vec3(dot(main_tex, GREY)), main_tex, saturation);

		COLOR = vec4(clamp(main_tex, vec3(0.0), vec3(1.0)), 1.0);
	}
}
