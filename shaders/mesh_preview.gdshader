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
uniform highp float reveal = 1.0;
uniform highp float roughness = 0.6;

void fragment() {
	// A null texture samples as black, so the shell supplies a flat grey
	// texture when a map is cleared: mixing grey with grey is grey.
	vec3 sampled = texture(map, UV).rgb;
	vec3 neutral = vec3(0.5, 0.5, 0.5);
	ALBEDO = mix(neutral, sampled, vec3(reveal));
	ROUGHNESS = roughness;
}
