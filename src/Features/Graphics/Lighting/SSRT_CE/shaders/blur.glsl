#[compute]
#version 450

#include "includes/scene_data.glsl"

struct SSRTData {
	vec4 sky_color;
	
	float rays_amount;
	float steps_per_ray;
	float bounce_intensity;
	float occlusion_intensity;
	float ray_length;
	float z_thickness;
	float sky_color_intensity;
	float far_plane;

	int blur_kernel_size;
	int blur_steps;

	bool depth_affect_ray_length;
	bool back_face_lighting;
};

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Set 0
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
} scene;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(rgba16f, set = 0, binding = 2) uniform image2D depth_image;
layout(rgba16f, set = 0, binding = 3) uniform image2D normal_roughness_image;

// Set 1
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;


float get_linear_depth(ivec2 uv)
{
	float depth = imageLoad(depth_image, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	vec4 view = scene.data.inv_projection_matrix * vec4(ndc, 1.0);
	view.xyz /= view.w;

	return -view.z;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {return;}

	vec3 color = imageLoad(color_image, uv).rgb;

	vec4 GI_TL = imageLoad(in_image, uv + ivec2(-2,-2));
	vec4 GI_TC = imageLoad(in_image, uv + ivec2(0,-2));
	vec4 GI_TR = imageLoad(in_image, uv + ivec2(2,-2));
	vec4 GI_L = imageLoad(in_image, uv + ivec2(-2,0));
	vec4 GI_C = imageLoad(in_image, uv + ivec2(0,0));
	vec4 GI_R = imageLoad(in_image, uv + ivec2(2,0));
	vec4 GI_BL = imageLoad(in_image, uv + ivec2(-2,2));
	vec4 GI_BC = imageLoad(in_image, uv + ivec2(0,2));
	vec4 GI_BR = imageLoad(in_image, uv + ivec2(2,2));

	vec4 GI = GI_TL + GI_TC + GI_TR + GI_L + GI_C + GI_R + GI_BL + GI_BC + GI_BR;
	GI /= 9.0;

	imageStore(color_image, uv, vec4(mix(color + color * GI.rgb, vec3(0), GI.a), 1.0));
}
