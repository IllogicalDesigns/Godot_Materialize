shader_type spatial;

// The 3D preview material, standing in for Materialize's `testObject` material
// (`MainGui.cs` uses `SampleMaterial` and sets `_MainTex` when a map's Preview
// button is pressed, plus the "Height Reveal Slider" blend).
//
// `map` is the current map as an 8-bit texture, `reveal` is the Height Reveal
// Slider (0..1): at 1.0 the mesh shows the map, at 0.0 it shows mid-grey, so
// dragging reveal shows how much relief is visible without touching the map.
// The shader lives in `shaders/` because the preview material is app-level: any
// map the user previews goes through it, not just Height.
//
// `repeat_enable` tiles the texture, so the box mesh shows each face tiled and
// tiling seams are visible, which is what Materialize's "Tile Maps" check is for.
//
// No `source_color` hint: the maps are display-referred values that the pass
// framework writes directly, so the texture is sampled raw, exactly as the map
// box previews show it.

uniform sampler2D map : filter_linear, repeat_enable;
// The source image for the Diffuse Reveal Slider split. Unity's
// `Edit_Diffuse_Preview.shader` samples `_MainTex` on the left of `_Slider`
// (the source) and `_ResultTex` on the right (the edited map); `original` is
// that source copy, written by the shell whenever the source image changes.
uniform sampler2D original : filter_linear, repeat_enable;
uniform highp float reveal = 1.0;
// The split seam for the Diffuse Reveal Slider. 0 means no split, and the
// grey-mix `reveal` above is in effect (the Height Reveal Slider). Above 0,
// UV.x < split_reveal shows `original` and the rest shows `map`.
uniform highp float split_reveal = 0.0;
uniform highp float roughness = 0.6;

// Normal map preview mode: the map is tangent-space normal data, so the mesh
// shades it. Materialize's `Normal_From_Height_Preview.shader` lerps the
// `lightDot` shading towards the raw normal colours by `_Slider` (the Normal
// Reveal Slider), and the port blends the same way. `PREVIEW_LIGHT` stands in
// for the `_LightDir` Unity sets from a script.
uniform highp float is_normal = 0.0;
const vec3 PREVIEW_LIGHT = normalize(vec3(0.4, 0.4, 0.85));

void fragment() {
	// A null texture samples as black, so the shell supplies a flat grey
	// texture when a map is cleared: mixing grey with grey is grey.
	vec3 sampled = texture(map, UV).rgb;

	if (is_normal > 0.5) {
		// Signed normal storage: 0.5 is neutral, so the map decodes to the
		// -1..1 vector it holds. Shaded relief at reveal 0, raw colours at
		// reveal 1, the same blend Materialize's preview uses.
		vec3 normal = normalize(sampled * 2.0 - 1.0);
		float light_dot = dot(normal, PREVIEW_LIGHT) * 0.5 + 0.5;
		light_dot *= light_dot;
		ALBEDO = vec3(0.0, 0.0, 0.0);
		EMISSION = mix(vec3(light_dot, light_dot, light_dot), sampled, vec3(reveal));
	} else if (split_reveal > 0.0) {
		// Diffuse Reveal Slider: the source image left of the seam, the
		// edited map right of it. The seam runs along UV.x, the same way
		// Unity's split preview on the test object works.
		if (UV.x < split_reveal) {
			ALBEDO = texture(original, UV).rgb;
		} else {
			ALBEDO = sampled;
		}
	} else {
		vec3 neutral = vec3(0.5, 0.5, 0.5);
		ALBEDO = mix(neutral, sampled, vec3(reveal));
	}
	ROUGHNESS = roughness;
}
