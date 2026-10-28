#[compute]
#version 450

#include "includes/scene_data.glsl"
#include "includes/reprojection.glsl"

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
//EMA history, one RGBA16F frame. Kept sampleable so a future reprojection pass
//can read it at an offset UV.
layout(rgba16f, set = 1, binding = 2) uniform image2D history;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
	float accumulation_weight;
	float history_valid;
	float reprojection_enabled;
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

	//EMA temporal accumulation. `history` holds the running estimate; blend the
	//current denoised GI into it with weight = 2/(N+1) (matches a flat ~N-frame
	//average; N=1 -> weight 1 -> no accumulation). First frame (history_valid = 0)
	//uses the current estimate directly so uninitialized history is never read.
	//Reprojection: the estimate for the world point now at `uv` lives at its
	//previous-frame position, so the read is reprojected; the current frame is
	//always written at uv. Same-texel write-then-read is ordered within one
	//invocation, so no atomic is needed.
	float raw_depth = imageLoad(depth_image, uv).r;
	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);
	ivec2 read_uv = uv;
	float history_valid = params.history_valid;
	if(params.reprojection_enabled > 0.5) {
		vec2 prev_px;
		bool in_bounds;
		get_reprojected_px(
			scene.data.inv_projection_matrix, scene.data.inv_view_matrix,
			scene.prev_data.projection_matrix, scene.prev_data.view_matrix,
			uv_center, raw_depth, size, prev_px, in_bounds);
		if(in_bounds) {
			read_uv = ivec2(prev_px);
		} else {
			//Previous position off-screen: no valid history for this pixel.
			history_valid = 0.0;
		}
	}
	vec4 acc = GI;
	if(history_valid > 0.5) {
		vec4 hist = imageLoad(history, read_uv);
		acc = mix(hist, GI, params.accumulation_weight);
	}
	imageStore(history, uv, acc);

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
