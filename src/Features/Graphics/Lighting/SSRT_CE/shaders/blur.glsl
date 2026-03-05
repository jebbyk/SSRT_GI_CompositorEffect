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

layout(constant_id = 0) const int OFFSET = 1;
// const int OFFSET = 1;

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

//Set 1
layout(set = 1, binding = 0, std140) uniform SSRTDataBlock {
	SSRTData data;
} settings;

// Set 2
layout(rgba16f, set = 2, binding = 0) uniform image2D in_image;
layout(rgba16f, set = 2, binding = 1) uniform image2D out_image;

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

vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	
	//return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
	vec4 nr = vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0), roughness);
	nr.gb = -nr.gb;
	return nr;
	//return vec4(p_normal_roughness.xyz, 1.0);
}

vec4 testSample(ivec2 uv, vec3 normal_c, float depth_c)
{
	// vec3 normal = normal_roughness_compatibility(imageLoad(normal_roughness_image, uv)).xyz;
	// float depth = get_linear_depth(uv);
	
	// if(dot(normal, normal_c) < 0.9) return vec4(0);
	// if(mod(depth, depth_c) > 64.0) return vec4(0);
	
	return imageLoad(in_image, uv);
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {return;}

	vec3 normal = normal_roughness_compatibility(imageLoad(normal_roughness_image, uv)).xyz;

	vec4 GI = vec4(0.0);

	GI += testSample(uv + ivec2(-OFFSET, -OFFSET), normal, depth);
	GI += testSample(uv + ivec2(0, -OFFSET), normal, depth);
	GI += testSample(uv + ivec2(OFFSET, -OFFSET), normal, depth);

	GI += testSample(uv + ivec2(-OFFSET, 0), normal, depth);
	GI += testSample(uv + ivec2(0, 0), normal, depth);
	GI += testSample(uv + ivec2(OFFSET, 0), normal, depth);
	
	GI += testSample(uv + ivec2(-OFFSET, OFFSET), normal, depth);
	GI += testSample(uv + ivec2(0, OFFSET), normal, depth);
	GI += testSample(uv + ivec2(OFFSET, OFFSET), normal, depth);

	GI /= 9.0;

	imageStore(out_image, uv, GI);
}
