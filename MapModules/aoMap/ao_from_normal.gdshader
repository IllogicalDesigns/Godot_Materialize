shader_type canvas_item;

// AO Map tool, ported from Materialize's Assets/Shaders/Resources/
// Blit_Shader.shader pass 7 (fragAO, lines 344-415) and pass 8
// (fragCombineAO, lines 417-432), the pair AOFromNormalGui runs.
//
// One shader holds the passes of the tool, and the GDScript driver picks one
// with the `pass` uniform - exactly like Unity picked a SubShader pass:
//
//   pass 1 AO      - fragAO: one ray direction per pass (_Progress turns the
//                    direction a full circle), 50 samples along the ray. The
//                    normal term is a weighted mean over the samples, the
//                    height term the strongest geometric occlusion, and the
//                    result is lerped into the accumulator at 1 / pass index,
//                    so 99 passes read as a running mean of ~100 directions.
//   pass 2 COMBINE - fragCombineAO: lerp the normal AO and the depth AO at
//                    "Blend Normal AO and Depth AO", add "AO Bias", raise to
//                    the power of "AO Power", saturate.
//
// UV mirroring, the frame conversion the port needs: Godot's UV points down,
// Unity's up, so the ray direction, the sample offsets, and the normal's Y
// component are all negated. Unity's default `_FlipNormalY == 0` mirror
// (fragAO lines 350-353) becomes this conversion, so the port reads its stored
// signed normal raw (the convention `normal_from_height.gdshader` writes).
//
// Unity ping-pongs the accumulator: pass 7 reads `_BlendTex` (the previous
// blend map), writes the working map, and a plain copy blit moves the working
// map into the blend map (`AOFromNormalGui.cs` lines 323-324). The port keeps
// one accumulator Image and feeds it back as the `accumulator` sampler, the
// same accumulation with one pass per iteration.
//
// Deviations: Unity applies AO Power, AO Bias and the blend to the preview
// material every frame while dragging (`AOFromNormalGui.cs` lines 159-161) and
// bakes them in pass 8 at Set time; the port bakes the grade inside pass 2, so
// the shell's debounce re-runs the combine pass on every settle. Unity seeds
// the ray jitter from `_Time.y` (fragAO line 362), a per-frame clock Godot has
// no equivalent of; the value is unused by the pass, so the port skips it.
//
// Data space: raw 0..1 file values (display-referred) stored in float
// textures, the same space the Height, Diffuse, Normal, Metallic and
// Roughness tools work in.

const int PASS_AO = 1;
const int PASS_COMBINE = 2;

// Unity's 50-sample ray per pass, fragAO line 361 (`int AOSamples = 50`), as
// a uniform so a test can shrink the sweep.
uniform int samples = 50;

const float TAU = 6.28318530718;

// The Normal map, Unity's `_MainTex` / `_NormalMap`, the pass source.
uniform sampler2D source : filter_linear, repeat_enable;
// The Height map, Unity's `_HeightTex` (`_HDHeightMap` first, then
// `_HeightMap`; the port has one height map).
uniform sampler2D height : filter_linear, repeat_enable;
// The running mean, Unity's `_BlendTex` (`_BlendedAOMap`), the accumulator the
// driver keeps between passes.
uniform sampler2D accumulator : filter_linear, repeat_enable;

uniform highp vec2 texel = vec2(0.001, 0.001);
uniform highp int pass = 1;

// --- AO pass ----------------------------------------------------------------

// Unity `_Progress`: the ray direction sweeps the full circle as
// progress = i / 100 over the 99 passes.
uniform highp float progress = 0.01;
// Unity `_BlendAmount` = 1 / pass index, the accumulator lerp weight.
uniform highp float blend_amount = 0.01;
// "AO pixel Spread": the ray length in pixels, Unity `_Spread`.
uniform highp float spread = 50.0;
// "Pixel Depth": how steep a height step counts, Unity `_Depth`.
uniform highp float depth = 100.0;

// --- Combine pass -------------------------------------------------------------

// "Blend Normal AO and Depth AO", Unity `_AOBlend`.
uniform highp float blend = 1.0;
// "AO Power", Unity `_FinalContrast`.
uniform highp float final_contrast = 1.0;
// "AO Bias", Unity `_FinalBias`.
uniform highp float final_bias = 0.0;

float saturate(highp float value) {
	return clamp(value, 0.0, 1.0);
}

// Unity's rand() hash, same port the normal map shader uses.
float rand(vec3 co) {
	return fract(sin(dot(co, vec3(12.9898, 78.233, 37.7198))) * 43758.5453);
}

// Unity normalize() of a vector that can be zero-length in edge cases, the
// same guard the other ported shaders use.
vec3 safe_normalize(vec3 v) {
	return v / max(length(v), 0.0001);
}

void fragment() {
	if (pass == PASS_COMBINE) {
		// fragCombineAO, Blit_Shader pass 8: lerp the two AO channels, then
		// AO Bias, AO Power, saturate.
		highp vec2 ao = texture(accumulator, SCREEN_UV).xy;
		highp float a = mix(ao.x, ao.y, blend);
		a += final_bias;
		// Unity pow()s straight after the bias. pow() of a negative base is
		// undefined in GLSL, so the port clamps to 0 first, documented.
		a = pow(max(a, 0.0), final_contrast);
		a = saturate(a);
		COLOR = vec4(vec3(a), 1.0);
		return;
	}

	highp vec2 uv = SCREEN_UV;

	// Unity's mainTex, normalized and flipped; fragAO never reads it after
	// the flip, so the port keeps it only to mirror the pass faithfully.
	highp vec3 main_tex = safe_normalize(texture(source, uv).rgb * 2.0 - 1.0);
	main_tex.y = -main_tex.y;
	highp float main_height = texture(height, uv).r;

	// fragAO line 369: the ray direction from _Progress, one full turn per
	// generation. Godot's Y-down frame negates the Y, see the header.
	highp vec2 direction = vec2(sin(progress * TAU), cos(progress * TAU));

	highp vec2 ao = vec2(0.0, 0.0);
	highp float ao_accum = 0.0;

	for (int i = 1; i <= samples; i += 1) {
		highp float fi = float(i);
		highp float p = fi / float(samples);

		// fragAO line 378: the jitter, two hash channels scaled by the sample
		// position, so the ray wanders outward.
		highp vec2 randomizer = vec2(rand(vec3(uv, fi)), rand(vec3(uv.yx, fi))) * p * 0.1;
		highp vec2 uv_offset = direction * spread * p + randomizer;
		highp vec2 true_dir = safe_normalize(vec3(uv_offset, 0.0)).xy;

		// fragAO line 382: the sample pixel, Unity's pixelSize * uvOffset,
		// the Y negated for the port's UV frame, see the header.
		highp vec2 sample_uv = uv + texel * vec2(uv_offset.x, -uv_offset.y);

		highp vec3 sample_tex = texture(source, sample_uv).rgb * 2.0 - 1.0;
		sample_tex.y = -sample_tex.y;
		highp float sample_height = texture(height, sample_uv).r;

		// Normal Only, same as depth from normal: the ray tilting back
		// towards the surface is the occlusion the normal map reads, weighted
		// sqrt(1 - progress) so the far samples matter least.
		highp float sample_importance = sqrt(1.0 - p);
		ao.x += dot(sample_tex, vec3(true_dir.x, -true_dir.y, 0.0)) * sample_importance;
		ao_accum += sample_importance;

		// Depth Only, pure geometric occlusion: the ray in 3D with the height
		// step as Z, the tangent Y negated into the port's frame, and the
		// straight-up dot of the sample direction the strongest occlusion.
		highp vec3 sample_pos = vec3(true_dir.x, -true_dir.y, 0.0) * spread * p;
		sample_pos.z = (sample_height - main_height) * depth;
		highp float sample_dist = saturate(length(sample_pos) * 0.1);
		highp float sample_ao = saturate(dot(vec3(0.0, 0.0, 1.0), safe_normalize(sample_pos)));
		ao.y = max(sample_ao * sample_dist, ao.y);
	}

	// fragAO lines 401-406: the normal-AO curve. AO.x runs negative in
	// occluded directions, so the two saturate bands split the dark and light
	// parts, the pow(5) / pow(0.2) product shapes them, and the sqrt lifts the
	// curve back up.
	ao.x *= 1.0 / max(ao_accum, 0.0001);
	highp float ao_x1 = saturate(ao.x + 1.0); // Dark Parts
	highp float ao_x2 = saturate(ao.x + 0.5); // light parts
	ao.x = pow(ao_x1, 5.0);
	ao.x *= pow(ao_x2, 0.2);
	ao.x = sqrt(ao.x);

	// The depth term counts as occlusion, so 0 is open and 1 is closed, and
	// the pass output is the light side.
	ao.y = 1.0 - ao.y;

	// fragAO line 412: the running mean, Unity lerps the previous accumulator
	// at 1 / i. The first pass blends at 1.0 straight, so a black accumulator
	// seed leaves it out, the way Unity's empty blend texture does.
	highp vec2 blend_tex = texture(accumulator, uv).xy;
	ao = mix(blend_tex, ao, blend_amount);
	COLOR = vec4(ao.xy, 1.0, 1.0);
}
