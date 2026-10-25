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
layout(rgba16f, set = 0, binding = 2) uniform image2D depth_image;
layout(rgba16f, set = 0, binding = 3) uniform image2D normal_roughness_image;

// Set 1
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;
//Combined image+sampler (matches UNIFORM_TYPE_SAMPLER_WITH_TEXTURE in SSRT_CE.gd).
layout(set = 1, binding = 1) uniform sampler2D albedo_texture;
//N-frame RGBA8 history (depth = N). HDR RGB is stored * (1/256) so up to 256.0
//fits the UNORM 0..1 range and decodes * 256 after averaging (step ~1.0);
//AO stays in 0..1 as-is.
layout(rgba8, set = 1, binding = 2) uniform image3D history;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
	float slot_index;
	float valid_count;
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

	vec4 GI = imageLoad(in_image, uv);

	//Flat N-frame average: write the current frame to the rolling slot
	//(frame % N), then average the last min(frame+1, N) slots; the first frame
	//averages only itself, so uninitialized history is never read.
	//Reprojection-compatible: read at read_uv (== uv for now, later uv + motion),
	//write at uv. Same-texel write-then-read is ordered within one invocation.
	ivec2 read_uv = uv;
	imageStore(history, ivec3(uv, int(params.slot_index)), vec4(GI.rgb * (1.0 / 256.0), GI.a));
	vec4 acc = vec4(0.0);
	for(int i = 0; i < int(params.valid_count); i++) {
		acc += imageLoad(history, ivec3(read_uv, i));
	}
	acc /= params.valid_count;
	acc.rgb *= 256.0; //decode the UNORM RGB scale

	//When enabled, modulate the GI bounce by the scene's unlit albedo (rendered
	//by SSRTAlbedoSource) instead of the already-lit color, so directly-lit
	//surfaces are not overbrightened. Falls back to the legacy lit-color
	//modulation when ALBEDO_GI is off or the albedo size is not available.
	vec3 albedo = color;
	if(ALBEDO_GI && params.albedo_size.x > 0.0 && params.albedo_size.y > 0.0) {
		vec2 albedo_uv = vec2(uv) / params.albedo_size;
		albedo = texture(albedo_texture, albedo_uv).rgb;
	}

	imageStore(color_image, uv, vec4(mix(color + albedo * acc.rgb, vec3(0), acc.a), 1.0));
}
