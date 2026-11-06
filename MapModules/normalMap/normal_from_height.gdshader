shader_type canvas_item;

// Normal From Height, ported from Materialize's
// Assets/Shaders/Resources/Blit_Shader.shader (passes 1, 3 and 4) and
// Assets/Shaders/Resources/Blit_Normal_From_Height.shader (sobel maths).
//
// One shader holds the passes of the tool, and the GDScript driver picks one
// with the `pass` uniform, exactly like Unity picked a SubShader pass:
//
//   pass 1 BLUR    - one separable axis of the raised-cosine box blur. Two
//                    kernels: `wide` is the Slope Blur window (the shape
//                    reference), the narrow one is the pyramid level.
//   pass 3 NORMAL  - sobel slopes of the height map, plus the
//                    `Shape Recognition` shape from `Light Rotation` and
//                    `Shape Bias`.
//   pass 4 COMBINE - the seven pyramid levels re-blend by the Frequency
//                    Equalizer weights, then `Angularity` / `Angular
//                    Intensity`, then `Final Contrast`.
//
// Data space: the maps ride in float textures, and the normal map keeps
// Materialize's signed convention (0.5 = neutral), so a flat surface is 0.5
// grey, not black.

const int PASS_BLUR = 1;
const int PASS_NORMAL = 3;
const int PASS_COMBINE = 4;

// Materialize's luminance weights, not the standard 0.299 / 0.587 / 0.114.
const vec3 GREY = vec3(0.3, 0.5, 0.2);

// Taps on each side of the centre. Godot shader loops need a constant bound,
// so the two kernels are two loops: the Slope Blur window is 100 taps each
// side, the pyramid blur is 4 (`_BlurSamples = 4` in the Unity pass), and
// `radius` scales the taps inside each window.
const int WIDE_SAMPLES = 100;
const int BLUR_SAMPLES = 4;

// Unity's `saturate()` is HLSL, not GLSL, so the port defines it, the same way
// `MapModules/diffuseMap/edit_diffuse.gdshader` does.
float saturate(highp float value) {
	return clamp(value, 0.0, 1.0);
}

uniform sampler2D source : filter_linear, repeat_enable;
uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 1;

// --- Blur pass ---------------------------------------------------------------

uniform highp vec2 direction = vec2(1.0, 0.0);
uniform highp float spread = 1.0;
uniform highp float radius = 4.0;
uniform highp int wide = 0;
uniform highp int desaturate = 0;
// `Pre Contrast` rides in here for the normal pass; every blur pass runs
// with contrast at 1.0, the same as Materialize.
uniform highp float blur_contrast = 1.0;

// --- Normal pass -------------------------------------------------------------

// The light source for `Shape Recognition`: the desaturated diffuse when
// "Shape from Diffuse" is on, otherwise the height map. `light_blur` is its
// wide blurred version, the shape reference. Level 0 of the pyramid is the
// `source` sampler, so it is not declared again.
uniform sampler2D light_map : filter_linear, repeat_enable;
uniform sampler2D light_blur : filter_linear, repeat_enable;

// `Light Rotation` is radians, `Shape Bias` centres the shape height, and
// `Shape Recognition` is the lerp weight between the sobel normal and the
// shape.
uniform highp float light_rotation = 0.0;
uniform highp float shape_recognition = 0.0;
uniform highp float shape_bias = 0.5;

// --- Combine pass -------------------------------------------------------------

uniform sampler2D blur1 : filter_linear, repeat_enable;
uniform sampler2D blur2 : filter_linear, repeat_enable;
uniform sampler2D blur3 : filter_linear, repeat_enable;
uniform sampler2D blur4 : filter_linear, repeat_enable;
uniform sampler2D blur5 : filter_linear, repeat_enable;
uniform sampler2D blur6 : filter_linear, repeat_enable;

uniform highp float weight0 = 0.3;
uniform highp float weight1 = 0.35;
uniform highp float weight2 = 0.5;
uniform highp float weight3 = 0.8;
uniform highp float weight4 = 1.0;
uniform highp float weight5 = 0.95;
uniform highp float weight6 = 0.8;

// `Angularity` pulls the normals towards the light, `Angular Intensity`
// decides how far they are pulled, and `Final Contrast` re-sharpens the
// result.
uniform highp float angularity = 0.0;
uniform highp float angular_intensity = 0.5;
uniform highp float final_contrast = 5.0;

// Raised-cosine windowed box blur along one axis: Materialize's fragBlur. The
// window fades the edge taps to zero, so stacked blur levels combine without
// hard seams. `radius / window` puts the window's zero-weight edge at
// `radius` pixels, so the slope reference stays tileable.

void fragment() {
	if (pass == PASS_BLUR) {
		highp vec2 uv = SCREEN_UV;
		highp vec3 sum = vec3(0.0, 0.0, 0.0);
		highp float weight_sum = 0.0;

		if (wide == 1) {
			// The Slope Blur window: `_BlurSamples = SlopeBlur` taps, as wide
			// as the slider dials.
			for (int i = -WIDE_SAMPLES; i <= WIDE_SAMPLES; i += 1) {
				highp float weight = cos(float(i) / float(WIDE_SAMPLES * 2) * TAU) * 0.5 + 0.5;
				highp float offset = float(i) * spread * radius / float(WIDE_SAMPLES);
				highp vec3 tap = texture(source, uv + direction * texel * offset).rgb;
				if (desaturate == 1) {
					highp float grey = dot(tap, GREY);
					tap = vec3(grey, grey, grey);
				}
				sum += tap * weight;
				weight_sum += weight;
			}
		} else {
			// The pyramid level: Materialize's 9-tap `_BlurSamples = 4` kernel.
			for (int i = -BLUR_SAMPLES; i <= BLUR_SAMPLES; i += 1) {
				highp float weight = cos(float(i) / float(BLUR_SAMPLES * 2) * TAU) * 0.5 + 0.5;
				highp float offset = float(i) * spread * radius / float(BLUR_SAMPLES);
				sum += texture(source, uv + direction * texel * offset).rgb * weight;
				weight_sum += weight;
			}
		}

		highp vec3 blurred = sum / max(weight_sum, 0.0001);
		COLOR = vec4(clamp((blurred - 0.5) * blur_contrast + 0.5, 0.0, 1.0), 1.0);
	} else if (pass == PASS_NORMAL) {
		// fragNormal: sobel slopes from the height map. Godot's UV points
		// down, so the vertical slope is the negated screen slope, which keeps
		// the sobel normal pointing up out of the surface.
		highp vec2 uv = SCREEN_UV;
		highp vec3 main_tex = texture(source, uv).rgb;
		highp vec3 ddx = texture(source, uv + vec2(texel.x, 0.0)).rgb - main_tex;
		highp vec3 ddy = texture(source, uv + vec2(0.0, texel.y)).rgb - main_tex;

		highp vec3 slope_x = vec3(1.0, 0.0, ddx.x * blur_contrast);
		highp vec3 slope_y = vec3(0.0, 1.0, -ddy.x * blur_contrast);
		highp vec3 normal_dir = normalize(cross(normalize(slope_x), normalize(slope_y)));

		// `Shape Recognition` blends the sobel normal with the broad shape
		// built from the light reference: the wide blur erases mid-frequency
		// detail, so the difference between the sharp and the blurred grey is
		// the shape, tilted by `Light Rotation` and centred by `Shape Bias`.
		highp vec3 light = texture(light_map, uv).rgb;
		if (desaturate == 1) {
			highp float grey = dot(light, GREY);
			light = vec3(grey, grey, grey);
		}
		highp float shape_height = (light.x - texture(light_blur, uv).x) + shape_bias;
		shape_height = shape_height * 2.0 - 1.0;

		highp vec3 light_dir = vec3(sin(light_rotation), cos(light_rotation), 0.0);
		highp vec3 light_cross = cross(light_dir, vec3(0.0, 0.0, 1.0));
		highp vec3 shape = (shape_height * light_dir) + (dot(normal_dir, light_cross) * light_cross);
		shape.z = sqrt(1.0 - saturate(dot(shape.xy, shape.xy)));
		shape = normalize(shape);

		highp vec3 normal_out = normalize(mix(normal_dir, shape, shape_recognition));

		// Signed normal: 0.5 is neutral, so the map reads as mid-grey on a
		// flat surface.
		COLOR = vec4(normal_out * 0.5 + 0.5, 1.0);
	} else {
		// fragCombineNormal: the seven scales re-blend by the equalizer
		// weights. A normal map has no grey, so the weight sum normalises the
		// vectors directly, and the result is re-normalised.
		highp vec2 uv = SCREEN_UV;
		highp vec3 sum = (texture(source, uv).rgb * weight0)
				+ (texture(blur1, uv).rgb * weight1)
				+ (texture(blur2, uv).rgb * weight2)
				+ (texture(blur3, uv).rgb * weight3)
				+ (texture(blur4, uv).rgb * weight4)
				+ (texture(blur5, uv).rgb * weight5)
				+ (texture(blur6, uv).rgb * weight6);
		highp float weight_total = weight0 + weight1 + weight2 + weight3 + weight4 + weight5 + weight6;

		highp vec3 normal_dir = normalize(sum / max(weight_total, 0.0001) * 2.0 - 1.0);

		// `Angularity` pulls the normals towards the light direction, which
		// is Materialize's trick for making relief read as baked shading.
		highp vec3 angular_dir = normalize(vec3(normalize(vec3(normal_dir.xy, 0.001)).xy
				* angular_intensity, max(1.0 - angular_intensity, 0.001)));
		normal_dir = mix(normal_dir, angular_dir, angularity);

		// `Final Contrast` pushes the slopes away from neutral, in signed
		// space, and re-normalises.
		normal_dir.xy *= final_contrast;
		normal_dir.z = pow(clamp(normal_dir.z, 0.0, 1.0), final_contrast);
		normal_dir = normalize(normal_dir) * 0.5 + 0.5;

		COLOR = vec4(normal_dir, 1.0);
	}
}
