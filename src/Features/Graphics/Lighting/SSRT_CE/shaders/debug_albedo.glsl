#[compute]
#version 450

#include "includes/scene_data.glsl"

layout(constant_id = 0) const bool ALBEDO_GI = false;

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Set 0
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_image;

// Set 1
//Combined image+sampler (matches UNIFORM_TYPE_SAMPLER_WITH_TEXTURE in SSRT_CE.gd).
layout(set = 1, binding = 1) uniform sampler2D albedo_texture;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
} params;


#include "includes/common.glsl"
#include "includes/albedo.glsl"

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	//Sky (beyond the far plane): keep the lit color, no albedo there.
	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {
		return;
	}

	//Show exactly what the GI bounce multiplies by: the unlit albedo when a source
	//viewport is wired up, else the lit-color fallback (see get_albedo_modulation).
	vec3 lit_color = imageLoad(color_image, uv).rgb;
	vec3 albedo = get_albedo_modulation(uv, lit_color);
	imageStore(color_image, uv, vec4(albedo, 1.0));
}
