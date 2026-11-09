#[compute]
#version 450

#include "includes/scene_data.glsl"

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Set 0
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_image;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
} params;


void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	//Show EXACTLY what the GI reads: the raw scene-depth sample, as grayscale
	//(near = dark, far = bright, sky = white). If the image is flat, inverted, or
	//garbage, the depth sampler is returning wrong values — that is the bug.
	float raw_depth = texture(depth_image, uv).r;
	imageStore(color_image, uv, vec4(raw_depth, raw_depth, raw_depth, 1.0));
}
