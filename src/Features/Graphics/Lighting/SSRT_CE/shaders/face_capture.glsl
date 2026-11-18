#[compute]
#version 450

#include "includes/scene_data.glsl"

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Set 0: this side viewport's own scene buffers.
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_image;
layout(rgba16f, set = 0, binding = 3) uniform image2D normal_roughness_image;

// Set 1: face texture arrays owned by SSRT_CE; layer = face index.
layout(rgba16f, set = 1, binding = 0) uniform image2DArray face_color;
layout(rgba16f, set = 1, binding = 1) uniform image2DArray face_normal;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float face_index;
	float reserved;
} params;

#include "includes/common.glsl"

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	int layer = int(params.face_index);
	//rgb = lit color, a = linear distance along the face axis. Sky texels decode to
	//z_far: they can never pass the trace-side depth window, so offscreen rays miss
	//through to the sky.
	imageStore(face_color, ivec3(uv, layer), vec4(imageLoad(color_image, uv).rgb, get_linear_depth(uv)));
	//Native gbuffer normal + roughness, stored raw (the reader decodes with the same
	//compatibility function the main path uses).
	imageStore(face_normal, ivec3(uv, layer), imageLoad(normal_roughness_image, uv));
}
