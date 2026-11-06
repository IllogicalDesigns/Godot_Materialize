shader_type canvas_item;

// Ambient Occlusion, Materialize's Blit_Shader.shader fragAO (lines 344-415)
// and fragCombineAO (lines 417-432). The pass source is the Normal map,
// blitted straight from `_NormalMap` (AOFromNormalGui.cs line 323).
//
// Pass 1 is the accumulation pass, Unity's pass 7. Each pass sweeps a cone
// direction `direction = (sin(progress * TAU), cos(progress * TAU))` where
// progress = i / passes, and samples 50 points inside that cone at
// `UV + texel * uvOffset`, `uvOffset = direction * spread * j/50 +
// randomizer`. The normal term AO.x is the weighted dot product of the
// sampled normal against the cone direction; the depth term AO.y is the best
// occlusion found over the samples, built from `samplePos = cone offset *
// spread, (sampleHeight - mainHeight) * Depth` and the dot of that direction
// against the vertical axis. Unity applies the AO.x curve, then `AO.y = 1 -
// AO.y`, and lerps the pass result into the accumulator by `1 / i` — the
// running mean over the 100 passes. The accumulator carries AO.x in red and
// AO.y in green, the way Unity's blend texture does; Unity's blend texture
// starts black, so the accumulator starts as flat black.
//
// Pass 2 is the combine pass, Unity's pass 8: `AO = lerp(accumulator.x,
// accumulator.y, AOBlend)`, then the Final Bias is added, the Final Contrast
// power is applied, and the value is saturated. Materialize applies these in
// the preview material per frame (AOFromNormalGui.cs lines 159-161); this port
// bakes them into the stored map, so the stored texture matches the preview,
// and the panel re-runs the combine pass when a slider moves.
//
// Godot UV points down, Unity texture space points up. The stored normal's Y
// is negated at the frame conversion, which is exactly Unity's `_FlipNormalY`
// mirror, so the mirror flag is absorbed here. Unity's `startOffset` (line 362,
// seeded from `_Time.y`) is computed and never used, so it is dropped.
//
// The random hash is the sin fract hash; the ray seeds are unrelated between
// the GPU and the CPU mirror in `tests/ao_cpu.gd`, so the comparison there is
// on aggregate statistics, not per pixel.

uniform sampler2D source : source_color, filter_linear, repeat_enable;
uniform sampler2D accumulator : source_color, filter_linear, repeat_enable;
uniform sampler2D height_map : source_color, filter_linear, repeat_enable;

// The source texel size, bound by Blit (TEXEL_PARAM), the cone sample offset.
uniform highp vec2 texel = vec2(0.001, 0.001);

uniform int pass = 1;
uniform int i = 1;
uniform float progress = 0.01;
uniform float spread = 50.0;   // the Spread slider, 10..100
uniform float depth = 100.0;    // the Depth slider, 0..256, in height-map units
uniform float blend = 1.0;      // Unity's _AOBlend, the Normal/Depth lerp weight
uniform float final_contrast = 1.0;
uniform float final_bias = 0.0;

// The samples per pass. Unity hardcodes 50; tests shrink it with the driver's
// params, which also shrink the pass count.
uniform int samples = 50;

const int PASS_AO = 1;
const int PASS_COMBINE = 2;

vec3 rand(vec3 seed)
{
	vec3 s = seed * 12.9898;
	return fract(sin(vec3(dot(s, vec3(1.0, 2.0, 3.0)) + dot(s, vec3(7.0, 13.0, 17.0))) * 43758.5453));
}

float saturate(float x)
{
	return clamp(x, 0.0, 1.0);
}

// The stored normal, signed 0.5 neutral, decoded to tangent space and flipped
// into the Y-up frame Unity samples in.
vec3 decode_normal(vec4 stored)
{
	vec3 n = vec3(stored.r * 2.0 - 1.0, stored.g * 2.0 - 1.0, stored.b * 2.0 - 1.0);
	n.y = -n.y;
	float l = length(n);
	if (l < 1e-5)
	{
		return vec3(0.0, 0.0, 1.0);
	}
	return n / l;
}

void fragment()
{
	vec4 accum = texture(accumulator, SCREEN_UV);
	if (pass == PASS_AO)
	{
		vec3 mainTex = decode_normal(texture(source, SCREEN_UV));
		float mainHeight = texture(height_map, SCREEN_UV).g;
		// Unity lines 371-372, the cone direction for this pass.
		vec2 direction = vec2(sin(progress * TAU), cos(progress * TAU));
		float ao_x = 0.0;
		float weight = 0.0;
		float ao_y = 0.0;
		for (int j = 1; j <= samples; j++)
		{
			float prog = float(j) / float(samples);
			// Unity lines 377-378, the per-sample randomizer inside the cone.
			vec3 seed = vec3(SCREEN_UV * 320.0, float(i * 100 + j));
			vec2 randomizer = vec2(rand(seed).x, rand(seed.zyx).x) * prog * 0.1;
			vec2 uv_offset = direction * spread * prog + randomizer;
			vec2 true_dir = normalize(uv_offset);
			vec2 sample_uv = SCREEN_UV + texel * uv_offset;
			vec3 sample_tex = decode_normal(texture(source, sample_uv));
			float sample_height = texture(height_map, sample_uv).g;
			// Unity lines 387-389, the normal term: the dot of the sampled
			// normal with the cone direction, weighted by sqrt(1 - progress).
			float importance = sqrt(1.0 - prog);
			ao_x += dot(sample_tex, vec3(true_dir, 0.0)) * importance;
			weight += importance;
			// Unity lines 391-394, the depth term: the best occlusion found,
			// the z dot of the sample direction scaled by its distance.
			vec3 sample_pos = vec3(true_dir * spread * prog, (sample_height - mainHeight) * depth);
			float dist = saturate(length(sample_pos) * 0.1);
			float l = length(sample_pos);
			float ao_sample = 0.0;
			if (l > 1e-5)
			{
				ao_sample = saturate(sample_pos.z / l) * dist;
			}
			ao_y = max(ao_sample, ao_y);
		}
		ao_x /= max(weight, 1e-5);
		// Unity lines 400-404, the AO.x curve.
		float ao_x1 = saturate(ao_x + 1.0);
		float ao_x2 = saturate(ao_x + 0.5);
		ao_x = pow(ao_x1, 5.0) * pow(ao_x2, 0.2);
		ao_x = sqrt(ao_x);
		ao_y = 1.0 - ao_y;
		// Unity line 409, the running mean into the accumulator, weight 1 / i.
		float blend_amount = 1.0 / float(i);
		COLOR = vec4(mix(accum.rg, vec2(ao_x, ao_y), blend_amount), 0.0, 1.0);
	}
	else
	{
		// Unity fragCombineAO lines 423-428. The Final Bias can push the value
		// negative; pow of a negative base is undefined in GLSL, so the base
		// is clamped at zero, which Unity's HDR float textures keep.
		float a = mix(accum.r, accum.g, blend) + final_bias;
		a = pow(max(a, 0.0), final_contrast);
		a = saturate(a);
		COLOR = vec4(vec3(a), 1.0);
	}
}
