//Screen-space reprojection from the scene UBO's current/prev camera matrices.
//The matrices are passed individually because a block struct type (declared via
//"layout(...) uniform BlockName { ... } var;") cannot be used as a function
//parameter type in Godot's Vulkan GLSL mode.
//
//prev_data is zero-filled unless motion vectors are being calculated
//(CompositorEffect.needs_motion_vectors), so a zero prev projection means "no
//reprojection". Returns the previous-frame screen position in pixels
//(top-left origin, texel centers) and whether it was inside the viewport.
//
//The UBO stores the view/inv_view matrices as a TRANSPOSED mat3x4
//(store_transform_transposed_3x4), and this GLSL rejects mat3x4 * vec4, so the
//real mat4 is rebuilt exactly the way the engine's scene shaders do it.
//
//Uses the engine's uv*2-1 convention (see derive_motion_vector): the UBO
//projections are y-corrected for that space (set_depth_correction), so a raw
//screen uv maps straight through, and the raw depth is already Vulkan NDC z.
void get_reprojected_px(
	mat4 cur_inv_projection, mat3x4 cur_inv_view,
	mat4 prev_projection, mat3x4 prev_view,
	vec2 uv_center, float raw_depth, ivec2 size,
	out vec2 prev_px, out bool in_bounds)
{
	if(prev_projection[0][0] == 0.0) {
		prev_px = uv_center * vec2(size);
		in_bounds = true;
		return;
	}

	//m[i] is a vec4 column (mat3x4 = 3 cols x 4 rows); columns become the mat4
	//columns, then transpose undoes the transposed storage.
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
