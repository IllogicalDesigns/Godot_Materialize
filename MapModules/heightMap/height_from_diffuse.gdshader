shader_type canvas_item;

// Height From Diffuse, ported from Materialize's
// Assets/Shaders/Resources/Blit_Sample.shader and Blit_Shader.shader (passes 1 and 2).
//
// One shader holds all four passes of the tool, and the GDScript driver picks
// one with the `pass` uniform - exactly like Unity picked a SubShader pass:
//
//   pass 0 SAMPLE  - source image -> grey base height, with colour-sample masks
//   pass 1 BLUR    - one separable axis of the raised-cosine box blur
//   pass 2 COMBINE - weighted multi-scale sum -> final height map
//   pass 3 AVG     - very wide blur of level 6, the low-frequency reference
//                    subtracted so global lighting gradients disappear
//
// Data space: raw 0..1 file values (display-referred) stored in float
// textures. Materialize's signed convention is kept: 0.5 means neutral.

const int PASS_SAMPLE = 0;
const int PASS_BLUR = 1;
const int PASS_COMBINE = 2;
const int PASS_AVG = 3;

// Materialize's luminance weights, not the standard 0.299 / 0.587 / 0.114.
const vec3 GREY = vec3(0.3, 0.5, 0.2);

// Taps on each side of the centre for the pyramid blur (9 taps total),
// and for the average pass (65 taps total).
const int BLUR_SAMPLES = 4;
const int AVG_SAMPLES = 32;

uniform sampler2D source : filter_linear, repeat_enable;
uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 0;

// --- Sample pass -------------------------------------------------------------

uniform highp int use_sample1 = 0;
uniform highp int isolate_sample1 = 0;
uniform highp vec4 sample_color1 = vec4(0.0, 0.0, 0.0, 1.0);
uniform highp float hue_weight1 = 1.0;
uniform highp float sat_weight1 = 0.5;
uniform highp float lum_weight1 = 0.2;
uniform highp float mask_low1 = 0.0;
uniform highp float mask_high1 = 1.0;
uniform highp float sample1_height = 0.5;

uniform highp int use_sample2 = 0;
uniform highp int isolate_sample2 = 0;
uniform highp vec4 sample_color2 = vec4(0.0, 0.0, 0.0, 1.0);
uniform highp float hue_weight2 = 1.0;
uniform highp float sat_weight2 = 0.5;
uniform highp float lum_weight2 = 0.2;
uniform highp float mask_low2 = 0.0;
uniform highp float mask_high2 = 1.0;
uniform highp float sample2_height = 0.3;

uniform highp float sample_blend = 0.5;

// --- Blur and average passes -------------------------------------------------

uniform highp vec2 direction = vec2(1.0, 0.0);
uniform highp float spread = 1.0;
uniform highp float blur_contrast = 1.0;

// --- Combine pass ------------------------------------------------------------

// Level 0 is the `source` sampler, so it is not declared again here.
uniform sampler2D blur1 : filter_linear, repeat_enable;
uniform sampler2D blur2 : filter_linear, repeat_enable;
uniform sampler2D blur3 : filter_linear, repeat_enable;
uniform sampler2D blur4 : filter_linear, repeat_enable;
uniform sampler2D blur5 : filter_linear, repeat_enable;
uniform sampler2D blur6 : filter_linear, repeat_enable;
uniform sampler2D avg_map : filter_linear, repeat_enable;

uniform highp float weight0 = 0.15;
uniform highp float weight1 = 0.19;
uniform highp float weight2 = 0.3;
uniform highp float weight3 = 0.5;
uniform highp float weight4 = 0.7;
uniform highp float weight5 = 0.9;
uniform highp float weight6 = 1.0;

uniform highp float contrast0 = 1.0;
uniform highp float contrast1 = 1.0;
uniform highp float contrast2 = 1.0;
uniform highp float contrast3 = 1.0;
uniform highp float contrast4 = 1.0;
uniform highp float contrast5 = 1.0;
uniform highp float contrast6 = 1.0;

uniform highp float final_contrast = 1.5;
uniform highp float final_bias = 0.0;
// The UI gain slider is mapped to an exponent by the driver
// (HeightFromDiffuse.gain_mapping), so the shader uses it directly.
uniform highp float final_gain = 1.0;

// Ported from Assets/Shaders/Resources/Photoshop.cginc, Materialize's source
// of HSL maths for colour sampling.
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

// How close a pixel's colour is to a picked sample colour, weighted across
// hue, saturation and luminance, then windowed by the mask range. This is
// Blit_Sample.shader's fragSample mask maths, kept intact.
float sample_mask(vec3 pixel_hsl, vec3 sample_hsl, highp float hue_weight,
		highp float sat_weight, highp float lum_weight,
		highp float mask_low, highp float mask_high) {
	// Hue wraps, so compare the three candidate distances.
	highp float hue_diff = 1.0 - min(min(abs(pixel_hsl.x - sample_hsl.x),
			abs((pixel_hsl.x + 1.0) - sample_hsl.x)),
			abs((pixel_hsl.x - 1.0) - sample_hsl.x)) * 2.0;
	highp float sat_diff = 1.0 - abs(pixel_hsl.y - sample_hsl.y);
	highp float lum_diff = 1.0 - abs(pixel_hsl.z - sample_hsl.z);

	highp float mask = (hue_diff * hue_weight + sat_diff * sat_weight + lum_diff * lum_weight)
			/ max(hue_weight + sat_weight + lum_weight, 0.0001);

	// smoothstep needs a positive window; keep mask_high above mask_low.
	return smoothstep(mask_low, max(mask_high, mask_low + 0.0001), mask);
}

// Raised-cosine windowed box blur along one axis: Materialize's fragBlur,
// inlined in the fragment branches below. The window fades edge taps to zero,
// so stacked blur levels combine without hard seams. `direction` picks the
// axis, `spread` is the radius in source pixels. Samplers are sampled inline
// (no sampler function arguments) to keep the shader simple to compile.

void fragment() {
	if (pass == PASS_SAMPLE) {
		highp vec3 src = texture(source, SCREEN_UV).rgb;
		highp vec3 src_hsl = rgb_to_hsl(src);

		// The base is Materialize's weighted grey, not a luminance conversion.
		highp float base = dot(src, GREY);

		highp float mask1 = 0.0;
		if (use_sample1 == 1) {
			mask1 = sample_mask(src_hsl, rgb_to_hsl(sample_color1.rgb),
					hue_weight1, sat_weight1, lum_weight1, mask_low1, mask_high1);
		}

		highp float mask2 = 0.0;
		if (use_sample2 == 1) {
			mask2 = sample_mask(src_hsl, rgb_to_hsl(sample_color2.rgb),
					hue_weight2, sat_weight2, lum_weight2, mask_low2, mask_high2);
		}

		// Materialize applies sample 2 first, then sample 1, so sample 1 wins
		// where both masks are active.
		if (use_sample2 == 1) {
			base = mix(base, sample2_height, mask2 * sample_blend);
		}
		if (use_sample1 == 1) {
			base = mix(base, sample1_height, mask1 * sample_blend);
		}

		// Isolate modes output the mask itself, for dialling in mask ranges.
		if (isolate_sample1 == 1) {
			base = mask1;
		}
		if (isolate_sample2 == 1) {
			base = mask2;
		}

		base = clamp(base, 0.0, 1.0);
		COLOR = vec4(base, base, base, 1.0);
	} else if (pass == PASS_BLUR) {
		highp vec2 uv = SCREEN_UV;
		highp vec3 sum = vec3(0.0, 0.0, 0.0);
		highp float weight_sum = 0.0;

		for (int i = -BLUR_SAMPLES; i <= BLUR_SAMPLES; i += 1) {
			highp float weight = cos(float(i) / float(BLUR_SAMPLES * 2) * TAU) * 0.5 + 0.5;
			sum += texture(source, uv + direction * texel * float(i) * spread).rgb * weight;
			weight_sum += weight;
		}

		highp vec3 blurred = sum / max(weight_sum, 0.0001);
		COLOR = vec4(clamp((blurred - 0.5) * blur_contrast + 0.5, 0.0, 1.0), 1.0);
	} else if (pass == PASS_AVG) {
		// The average pass is the same kernel with a much wider window,
		// stored as grey.
		highp vec2 uv = SCREEN_UV;
		highp vec3 sum = vec3(0.0, 0.0, 0.0);
		highp float weight_sum = 0.0;

		for (int i = -AVG_SAMPLES; i <= AVG_SAMPLES; i += 1) {
			highp float weight = cos(float(i) / float(AVG_SAMPLES * 2) * TAU) * 0.5 + 0.5;
			sum += texture(source, uv + direction * texel * float(i) * spread).rgb * weight;
			weight_sum += weight;
		}

		highp float grey = dot(sum / max(weight_sum, 0.0001), GREY);
		COLOR = vec4(grey, grey, grey, 1.0);
	} else {
		// fragCombineHeight: every level contributes its deviation from the
		// low-frequency reference, gamma-lifted by pow(x, 0.45) so detail in
		// dark areas survives. Unity's contribution is `(deviation * contrast
		// + 0.5) * weight` - the +0.5 per level is essential: it centres the
		// sum on neutral mid-grey, so a flat source lands on 0.5 instead of 0
		// (which would clamp to black). The weight sum normalises the result.
		highp float avg = pow(texture(avg_map, SCREEN_UV).x, 0.45);

		highp float sum = ((pow(texture(source, SCREEN_UV).x, 0.45) - avg) * contrast0 + 0.5) * weight0;
		highp float weight_total = weight0;
		sum += ((pow(texture(blur1, SCREEN_UV).x, 0.45) - avg) * contrast1 + 0.5) * weight1;
		weight_total += weight1;
		sum += ((pow(texture(blur2, SCREEN_UV).x, 0.45) - avg) * contrast2 + 0.5) * weight2;
		weight_total += weight2;
		sum += ((pow(texture(blur3, SCREEN_UV).x, 0.45) - avg) * contrast3 + 0.5) * weight3;
		weight_total += weight3;
		sum += ((pow(texture(blur4, SCREEN_UV).x, 0.45) - avg) * contrast4 + 0.5) * weight4;
		weight_total += weight4;
		sum += ((pow(texture(blur5, SCREEN_UV).x, 0.45) - avg) * contrast5 + 0.5) * weight5;
		weight_total += weight5;
		sum += ((pow(texture(blur6, SCREEN_UV).x, 0.45) - avg) * contrast6 + 0.5) * weight6;
		weight_total += weight6;

		highp float height = sum / max(weight_total, 0.0001);

		height = clamp((height - 0.5) * final_contrast + 0.5 + final_bias, 0.0, 1.0);

		// Split gain: the bright and dark halves are pushed apart by pow()
		// around neutral mid-grey, mirrored so the map grows symmetrically.
		if (height > 0.5) {
			height = pow(clamp(height * 2.0 - 1.0, 0.0, 1.0), final_gain) * 0.5 + 0.5;
		} else {
			height = 1.0 - (pow(clamp((1.0 - height) * 2.0 - 1.0, 0.0, 1.0), final_gain) * 0.5 + 0.5);
		}

		COLOR = vec4(height, height, height, 1.0);
	}
}
