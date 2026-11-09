#[compute]
#version 450

#include "includes/scene_data.glsl"
#include "includes/reprojection.glsl"

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Set 0
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_image;
layout(set = 0, binding = 3) uniform sampler2D velocity_tex;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
} params;


#include "includes/common.glsl"

vec4 velocity_color(vec2 mv_px)
{
	//64 px of motion = full color range; a static scene stays black.
	return vec4(min(abs(mv_px) * (1.0 / 64.0), vec2(1.0)), 0.0, 1.0);
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	//Sky (beyond the far plane) has no reprojection target; black = no data.
	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {
		imageStore(color_image, uv, vec4(0.0));
		return;
	}

	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);

	//Engine velocity buffer: screen-space delta in UV units; (-1,-1) = engine left it unwritten.
	vec2 mv_uv = texture(velocity_tex, uv_center).xy;
	if(mv_uv != vec2(-1.0, -1.0)) {
		imageStore(color_image, uv, velocity_color(mv_uv * vec2(size)));
		return;
	}

	//Unwritten pixel: camera-only fallback (the sentinel makes get_reprojected_px skip the velocity path).
	float raw_depth = texture(depth_image, uv).r;
	vec2 prev_px;
	bool in_bounds;
	float d_exp;
	get_reprojected_px(
		mv_uv,
		scene.data.inv_projection_matrix, scene.data.inv_view_matrix,
		scene.prev_data.projection_matrix, scene.prev_data.view_matrix,
		uv_center, raw_depth, size, prev_px, in_bounds, d_exp);

	if(in_bounds) {
		imageStore(color_image, uv, velocity_color((vec2(uv) + 0.5) - prev_px));
	} else {
		//Previous position off-screen: no history available there.
		imageStore(color_image, uv, vec4(1.0, 0.0, 0.0, 1.0));
	}
}
