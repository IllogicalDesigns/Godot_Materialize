shader_type canvas_item;

// Metallic map tool, ported from Materialize's
// Assets/Shaders/Resources/Blit_Metallic.shader (fragMetallic) and the blur
// pass of Assets/Shaders/Resources/Blit_Shader.shader (fragBlur, pass 1), the
// same pass the Diffuse tool blurs with.
//
// One shader holds the passes of the tool, and the GDScript driver picks one
// with the `pass` uniform - exactly like Unity picked a SubShader pass:
//
//   pass 1 BLUR     - one separable axis of the raised-cosine blur. It runs for
//                     "Blur Size" (the map the metal colour is compared
//                     against) and for "Overlay Blur Size" (the map whose
//                     difference from the sharp source drives "High Pass
//                     Overlay").
//   pass 2 METALLIC - fragMetallic: hue / saturation / luminance distance from
//                     the picked metal colour, the smoothstep mask, the high
//                     pass overlay, and final contrast / bias. Output is a
//                     greyscale metallic mask.
//
// Data space: raw 0..1 file values (display-referred) stored in float
// textures, the same space the Height, Diffuse and Normal tools work in.

const int PASS_BLUR = 1;
const int PASS_METALLIC = 2;

// Materialize's luminance weights, not the standard 0.299 / 0.587 / 0.114.
const vec3 GREY = vec3(0.3, 0.5, 0.2);

// Taps on each side of the centre for one blur axis. The window is gated by
// the blur size, so taps past the active radius are skipped. Unity's "Blur
// Size" and "Overlay Blur Size" sliders both top out at 100.
const int BLUR_MAX = 100;

uniform sampler2D source : filter_linear, repeat_enable;
// The two blur maps, Materialize's `_BlurTex` and `_OverlayBlurTex`, supplied
// by the driver as extra samplers on the metallic pass.
uniform sampler2D blur_map : filter_linear, repeat_enable;
uniform sampler2D overlay_map : filter_linear, repeat_enable;

uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 1;

// --- Blur pass ---------------------------------------------------------------

uniform highp vec2 direction = vec2(1.0, 0.0);
uniform highp float blur_size = 20.0;

// --- Metallic pass -----------------------------------------------------------

// The picked metal colour, Materialize's `_MetalColor`. The Height panel's
// colour samples ride in the same way, as a vec4 uniform, and Unity converts
// the swatch to HSL directly (`metalHSL = RGBToHSL(_MetalColor.xyz)`), so the
// swatch value is the whole input the mask works from.
uniform highp vec4 metal_color = vec4(0.0, 0.0, 0.0, 1.0);
// "Hue", "Sat", "Lum": how much each colour distance counts in the mask.
uniform highp float hue_weight = 1.0;
uniform highp float sat_weight = 0.5;
uniform highp float lum_weight = 0.2;
// "Low" and "High", the smoothstep edges of the mask.
uniform highp float mask_low = 0.0;
uniform highp float mask_high = 1.0;
// "High Pass Overlay": the gain applied to the high pass overlay.
uniform highp float blur_overlay = 1.0;
// "Final Contrast" and "Final Bias".
uniform highp float final_contrast = 1.0;
uniform highp float final_bias = 0.0;

float saturate(highp float value) {
	return clamp(value, 0.0, 1.0);
}

// Ported from Assets/Shaders/Resources/Photoshop.cginc, the same HSL maths the
// Height, Diffuse and Normal tools' shaders use.
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

void fragment() {
	if (pass == PASS_BLUR) {
		// Raised-cosine windowed blur along one axis: Materialize's fragBlur.
		// One axis of Unity's single `fragBlur` pass: the GUI runs one horizontal
		// and one vertical pass per radius (`MetallicGui.cs` lines 479-514),
		// which is what this pass does. The window is Unity's
		// `cos(i / BlurSamples * PI) * 0.5 + 0.5` over the `±BlurSamples` taps.
		// `_BlurContrast` is 1.0 for the Metallic tool
		// (`MetallicGui.cs` line 486), which is the identity, so no contrast
		// term is applied here.
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
		// fragMetallic, Blit_Metallic pass 0, in order.
		highp vec3 main_tex = texture(source, SCREEN_UV).rgb;
		highp vec3 blur_tex = texture(blur_map, SCREEN_UV).rgb;
		highp vec3 overlay_blur = texture(overlay_map, SCREEN_UV).rgb;

		// High pass overlay: the sharp source minus the wide blur, seen as grey.
		highp vec3 overlay = main_tex - overlay_blur;
		highp float overlay_grey = dot(overlay, GREY);

		// Colour distance from the picked metal colour, measured on the
		// blur map. Unity samples the blur map at `_SampleUV` into
		// `metalSample` and then throws it away (`metalSampleHSL = metalHSL`
		// on line 69), so the picked swatch is the reference and the sample
		// position is not part of the mask.
		highp vec3 main_hsl = rgb_to_hsl(main_tex);
		highp vec3 blur_hsl = rgb_to_hsl(blur_tex);
		highp vec3 metal_hsl = rgb_to_hsl(metal_color.rgb);

		// Hue wraps, so Unity tests the three distances around the circle and
		// keeps the smallest. The * 2.0 sets the falloff: hues one half turn
		// apart score 0.
		highp float hue_dif = 1.0 - min(min(abs(blur_hsl.x - metal_hsl.x),
				abs((blur_hsl.x + 1.0) - metal_hsl.x)),
				abs((blur_hsl.x - 1.0) - metal_hsl.x)) * 2.0;
		highp float sat_dif = 1.0 - abs(blur_hsl.y - metal_hsl.y);
		highp float lum_dif = 1.0 - abs(blur_hsl.z - metal_hsl.z);

		highp float final_diff = hue_dif * hue_weight + sat_dif * sat_weight
				+ lum_dif * lum_weight;
		// Unity divides by the weight sum, which is only safe while at least
		// one weight is above 0. All three faders at 0 is a legal slider
		// state, so the port clamps the divisor instead of dividing by 0.
		final_diff *= 1.0 / max(hue_weight + sat_weight + lum_weight, 0.0001);
		final_diff = smoothstep(mask_low, mask_high, final_diff);

		final_diff = saturate((final_diff - 0.5) * final_contrast + 0.5 + final_bias);
		final_diff *= clamp(overlay_grey * blur_overlay + 1.0, 0.0, 10.0);
		final_diff = saturate(final_diff);

		COLOR = vec4(vec3(final_diff), 1.0);
	}
}
