shader_type canvas_item;

// Roughness map tool, ported from Materialize's
// Assets/Shaders/Resources/Blit_Smoothness.shader (fragSmoothness) and the blur
// pass of Assets/Shaders/Resources/Blit_Shader.shader (fragBlur, pass 1), the
// same pass the Metallic tool blurs with.
//
// One shader holds the passes of the tool, and the GDScript driver picks one
// with the `pass` uniform - exactly like Unity picked a SubShader pass:
//
//   pass 1 BLUR      - one separable axis of the raised-cosine blur. It runs for
//                      "Sample Blur Size" (the map the colour samples are
//                      compared against) and for "High Pass Blur Size" (the map
//                      whose difference from the sharp source drives "High Pass
//                      Overlay").
//   pass 2 ROUGHNESS - fragSmoothness: the base level, the two colour sample
//                      masks, the roughness where the metallic map is metal, the
//                      high pass overlay, and final contrast / bias. Output is a
//                      greyscale roughness map.
//
// Unity's numbers are smoothness (1.0 = mirror). The tool stores roughness, so
// the pass converts its roughness uniforms to smoothness, runs fragSmoothness
// unchanged, and writes 1 - smoothness back out. The "High Pass Overlay"
// multiplies smoothness, so it lifts smoothness and lowers roughness exactly as
// Unity does, which is why the maths stays in smoothness space.
//
// Data space: raw 0..1 file values (display-referred) stored in float
// textures, the same space the Height, Diffuse, Normal and Metallic tools work
// in.

const int PASS_BLUR = 1;
const int PASS_ROUGHNESS = 2;

// Materialize's luminance weights, not the standard 0.299 / 0.587 / 0.114.
const vec3 GREY = vec3(0.3, 0.5, 0.2);

// Taps on each side of the centre for one blur axis. The window is gated by
// the blur size, so taps past the active radius are skipped. Unity's "Sample
// Blur Size" and "High Pass Blur Size" sliders both top out at 100.
const int BLUR_MAX = 100;

uniform sampler2D source : filter_linear, repeat_enable;
// The two blur maps, Materialize's `_BlurTex` and `_OverlayBlurTex`, supplied
// by the driver as extra samplers on the roughness pass, plus the metallic map,
// Materialize's `_MetallicTex`.
uniform sampler2D blur_map : filter_linear, repeat_enable;
uniform sampler2D overlay_map : filter_linear, repeat_enable;
uniform sampler2D metal_map : filter_linear, repeat_enable;

uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 1;

// --- Blur pass ---------------------------------------------------------------

uniform highp vec2 direction = vec2(1.0, 0.0);
uniform highp float blur_size = 20.0;

// --- Roughness pass ----------------------------------------------------------

// "Metal Smoothness": the level metal gets, stored as roughness. Unity has no
// toggle for it, so the metallic map is the only control.
uniform highp float metal_roughness = 0.3;

// Sample 1: "Use Color Sample 1", "Isolate Mask", the swatch, and the six
// faders. Unity's defaults are the sample off with a black swatch. The swatch
// rides in as a vec4 uniform, the way the Height panel's colour samples do.
uniform bool use_sample1 = false;
uniform bool isolate_sample1 = false;
uniform highp vec4 sample_color1 = vec4(0.0, 0.0, 0.0, 1.0);
// "Hue", "Sat", "Lum": how much each colour distance counts in the mask.
uniform highp float hue_weight1 = 1.0;
uniform highp float sat_weight1 = 0.5;
uniform highp float lum_weight1 = 0.2;
// "Low" and "High", the smoothstep edges of the mask.
uniform highp float mask_low1 = 0.0;
uniform highp float mask_high1 = 1.0;
// "Smooth": the level sample 1 paints.
uniform highp float sample1_roughness = 0.5;

// Sample 2, the same block.
uniform bool use_sample2 = false;
uniform bool isolate_sample2 = false;
uniform highp vec4 sample_color2 = vec4(0.0, 0.0, 0.0, 1.0);
uniform highp float hue_weight2 = 1.0;
uniform highp float sat_weight2 = 0.5;
uniform highp float lum_weight2 = 0.2;
uniform highp float mask_low2 = 0.0;
uniform highp float mask_high2 = 1.0;
uniform highp float sample2_roughness = 0.7;

// "Base Smoothness", stored as roughness.
uniform highp float base_roughness = 0.9;
// "High Pass Overlay": the gain applied to the high pass overlay.
uniform highp float blur_overlay = 3.0;
// "Final Contrast" and "Final Bias", both in Unity's smoothness space.
uniform highp float final_contrast = 1.0;
uniform highp float final_bias = 0.0;

float saturate(highp float value) {
	return clamp(value, 0.0, 1.0);
}

// Ported from Assets/Shaders/Resources/Photoshop.cginc, the same HSL maths the
// Height, Diffuse, Normal and Metallic tools' shaders use.
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

// One colour sample mask, Unity's `sample1Mask` / `sample2Mask` lines
// (Blit_Smoothness.shader 98-118): the hue / saturation / luminance
// similarities from the swatch, weighted and averaged, then the smoothstep
// mask edges. The distances are measured on the blur map, the way Unity
// measures them, so the mask follows the smoothed colour and not the grain.
float sample_mask(highp vec4 sample_color, highp vec3 blur_hsl,
		highp float hue_weight, highp float sat_weight, highp float lum_weight,
		highp float mask_low, highp float mask_high) {
	highp vec3 sample_hsl = rgb_to_hsl(sample_color.rgb);

	// Hue wraps, so Unity tests the three distances around the circle and
	// keeps the smallest. The * 2.0 sets the falloff: hues one half turn
	// apart score 0.
	highp float hue_dif = 1.0 - min(min(abs(blur_hsl.x - sample_hsl.x),
			abs((blur_hsl.x + 1.0) - sample_hsl.x)),
			abs((blur_hsl.x - 1.0) - sample_hsl.x)) * 2.0;
	highp float sat_dif = 1.0 - abs(blur_hsl.y - sample_hsl.y);
	highp float lum_dif = 1.0 - abs(blur_hsl.z - sample_hsl.z);

	highp float mask = hue_dif * hue_weight + sat_dif * sat_weight
			+ lum_dif * lum_weight;
	// Unity divides by the weight sum, which is only safe while at least
	// one weight is above 0. All three faders at 0 is a legal slider
	// state, so the port clamps the divisor instead of dividing by 0.
	mask *= 1.0 / max(hue_weight + sat_weight + lum_weight, 0.0001);
	return smoothstep(mask_low, mask_high, mask);
}

void fragment() {
	if (pass == PASS_BLUR) {
		// Raised-cosine windowed blur along one axis: Materialize's fragBlur.
		// One axis of Unity's single `fragBlur` pass: the GUI runs one horizontal
		// and one vertical pass per radius (`SmoothnessGui.cs` lines 770-800),
		// which is what this pass does. The window is Unity's
		// `cos(i / BlurSamples * PI) * 0.5 + 0.5` over the `±BlurSamples` taps.
		// `_BlurContrast` and `_BlurSpread` are 1.0 for the Smoothness tool
		// (`SmoothnessGui.cs` lines 776-777), which is the identity, so no
		// contrast term is applied here.
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
		// fragSmoothness, Blit_Smoothness pass 0, in order.
		highp vec3 main_tex = texture(source, SCREEN_UV).rgb;
		highp vec3 blur_tex = texture(blur_map, SCREEN_UV).rgb;
		highp vec3 overlay_blur = texture(overlay_map, SCREEN_UV).rgb;

		// High pass overlay: the sharp source minus the wide blur, seen as grey.
		highp vec3 overlay = main_tex - overlay_blur;
		highp float overlay_grey = dot(overlay, GREY);

		// Where the metallic map is metal, the level is the metal level.
		highp float metal_mask = texture(metal_map, SCREEN_UV).x;

		highp vec3 blur_hsl = rgb_to_hsl(blur_tex);

		float sample1_mask = 0.0;
		if (use_sample1) {
			sample1_mask = sample_mask(sample_color1, blur_hsl, hue_weight1,
					sat_weight1, lum_weight1, mask_low1, mask_high1);
		}

		float sample2_mask = 0.0;
		if (use_sample2) {
			sample2_mask = sample_mask(sample_color2, blur_hsl, hue_weight2,
					sat_weight2, lum_weight2, mask_low2, mask_high2);
		}

		// The levels ride in as roughness, so the pass works in Unity's
		// smoothness space and inverts at the end. The lerp order is Unity's
		// lines 120-123: base, then sample 2, then sample 1, then metal.
		highp float final_smoothness = 1.0 - base_roughness;
		final_smoothness = mix(final_smoothness, 1.0 - sample2_roughness, sample2_mask);
		final_smoothness = mix(final_smoothness, 1.0 - sample1_roughness, sample1_mask);
		final_smoothness = mix(final_smoothness, 1.0 - metal_roughness, metal_mask);

		// Final Contrast and Final Bias, then the high pass overlay multiplies
		// the level, the way Unity's line 126 does.
		final_smoothness = saturate((final_smoothness - 0.5) * final_contrast
				+ 0.5 + final_bias);
		final_smoothness *= clamp(overlay_grey * blur_overlay + 1.0, 0.0, 10.0);
		final_smoothness = saturate(final_smoothness);

		// "Isolate Mask" paints the mask itself, Unity's lines 129-135.
		if (isolate_sample1) {
			final_smoothness = sample1_mask;
		}
		if (isolate_sample2) {
			final_smoothness = sample2_mask;
		}

		highp float final_roughness = saturate(1.0 - final_smoothness);

		COLOR = vec4(vec3(final_roughness), 1.0);
	}
}
