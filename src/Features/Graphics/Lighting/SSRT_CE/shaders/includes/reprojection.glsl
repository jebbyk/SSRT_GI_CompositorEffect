//Screen-space reprojection: per-object velocity if the engine wrote one, else the
//scene UBO's current/prev cameras (camera-only path).
//Matrices are passed individually: a block struct type can't be a function
//parameter in Godot's Vulkan GLSL mode.
//The UBO stores view/inv_view as a TRANSPOSED mat3x4 (and GLSL rejects mat3x4*vec4),
//so the real mat4 is rebuilt the way the engine's scene shaders do it.
//prev_data is zero-filled unless needs_motion_vectors — a zero prev projection means
//no reprojection. Returns the previous-frame position in texel centers (top-left
//origin) + in-bounds flag.
//Uses the engine's uv*2-1 convention: UBO projections are y-corrected for it
//(set_depth_correction), raw depth is already Vulkan NDC z.
void get_reprojected_px(
	vec2 velocity_uv,
	mat4 cur_inv_projection, mat3x4 cur_inv_view,
	mat4 prev_projection, mat3x4 prev_view,
	vec2 uv_center, float raw_depth, ivec2 size,
	out vec2 prev_px, out bool in_bounds)
{
	//Velocity buffer holds the full screen-space delta (camera + object) in UV units:
	//prev = cur + v is exact. (-1,-1) = engine left it unwritten (sky) -> camera-only path.
	if(velocity_uv != vec2(-1.0, -1.0)) {
		prev_px = (uv_center + velocity_uv) * vec2(size);
		in_bounds = prev_px.x >= 0.5 && prev_px.y >= 0.5
			&& prev_px.x <= float(size.x) - 0.5 && prev_px.y <= float(size.y) - 0.5;
		return;
	}
	if(prev_projection[0][0] == 0.0) {
		prev_px = uv_center * vec2(size);
		in_bounds = true;
		return;
	}

	//mat3x4 = 3 vec4 columns; rebuild the mat4, and transpose undoes the transposed storage.
	mat4 inv_view = transpose(mat4(cur_inv_view[0], cur_inv_view[1], cur_inv_view[2], vec4(0.0, 0.0, 0.0, 1.0)));
	mat4 view = transpose(mat4(prev_view[0], prev_view[1], prev_view[2], vec4(0.0, 0.0, 0.0, 1.0)));

	vec2 ndc = uv_center * 2.0 - 1.0;
	vec4 view_pos = cur_inv_projection * vec4(ndc, raw_depth, 1.0);
	view_pos /= view_pos.w;
	vec4 world_pos = inv_view * view_pos;
	vec4 prev_view_pos = view * world_pos;
	vec4 prev_ndc = prev_projection * prev_view_pos;
	prev_px = (0.5 + (prev_ndc.xy / prev_ndc.w) * 0.5) * vec2(size);
	in_bounds = prev_px.x >= 0.5 && prev_px.y >= 0.5
		&& prev_px.x <= float(size.x) - 0.5 && prev_px.y <= float(size.y) - 0.5;
}
