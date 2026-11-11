//The engine bakes fog into every pixel inside the object fragment shaders, before any
//compositor callback can run. Two consequences for a post-pass effect:
// 1. an added GI must be pre-attenuated: the engine writes color = lit*T + S, so
//    adding GI*T reproduces the pre-fog composite (lit+GI)*T + S;
// 2. the occlusion term multiplies the WHOLE pixel toward black — fog included, which
//    erases fog from occluded/distant pixels. Working in unfogged space and refogging:
//    (color - S)*(1-a) + GI*T*(1-a) + S  ==  color*(1-a) + S*a + GI*T*(1-a)
//    (no division; stable at T -> 0).
//S = fog_light_color * F reproduces the engine's scatter only while aerial_perspective
//and sun_scatter are 0 (they need octmaps/sun data a compositor effect cannot access).
//Volumetric fog's T lives in an internal 3D texture no effect can sample: fog volumes
//and VF extinction are not modeled here.
//params.fog_depth_mode mirrors Environment.fog_mode (the engine picks the branch as a
//pipeline specialization constant; it is not readable from the UBO).
//Returns vec4(scatter_rgb, transmittance); vec4(0,0,0,1) = "no fog correction".
//Uses scene, depth_image and params.* — declare them before this include.
vec4 get_fog_scatter_and_transmittance(ivec2 uv) {
	if(params.fog_attenuates_gi < 0.5) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	//SCENE_DATA_FLAGS_USE_FOG (render_scene_data_rd.h) — the engine's own gate.
	if((scene.data.flags & 16u) == 0u) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	vec2 uv_center = (vec2(uv) + 0.5) / params.raster_size;
	float raw_depth = texture(depth_image, uv_center).r;
	vec4 view_pos = scene.data.inv_projection_matrix * vec4(uv_center * 2.0 - 1.0, raw_depth, 1.0);
	view_pos /= view_pos.w;
	float dist = length(view_pos.xyz);

	float fog_amount;
	if(params.fog_depth_mode > 0.5) {
		float fog_z = smoothstep(scene.data.fog_depth_begin, scene.data.fog_depth_end, dist);
		fog_amount = pow(fog_z, scene.data.fog_depth_curve) * scene.data.fog_density;
	} else {
		fog_amount = 1.0 - exp(min(0.0, -dist * scene.data.fog_density));
	}

	if(abs(scene.data.fog_height_density) >= 0.0001) {
		mat4 inv_view = transpose(mat4(scene.data.inv_view_matrix[0],
				scene.data.inv_view_matrix[1],
				scene.data.inv_view_matrix[2],
				vec4(0.0, 0.0, 0.0, 1.0)));
		float y = (inv_view * view_pos).y;
		float vfog_amount = 1.0 - exp(min(0.0, (y - scene.data.fog_height) * scene.data.fog_height_density));
		fog_amount = max(vfog_amount, fog_amount);
	}

	fog_amount = clamp(fog_amount, 0.0, 1.0);
	return vec4(scene.data.fog_light_color * fog_amount, 1.0 - fog_amount);
}
