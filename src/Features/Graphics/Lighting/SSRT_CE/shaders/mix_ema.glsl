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
layout(set = 0, binding = 2) uniform sampler2D depth_image;
layout(rgba16f, set = 0, binding = 3) uniform image2D normal_roughness_image;
//Engine velocity buffer: per-object screen-space delta in UV units; preferred over the camera-only path.
layout(set = 0, binding = 4) uniform sampler2D velocity_tex;

// Set 1
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;
//Image+sampler (UNIFORM_TYPE_SAMPLER_WITH_TEXTURE in SSRT_CE.gd).
layout(set = 1, binding = 1) uniform sampler2D albedo_texture;
//History read slot; `history_write` gets this frame's write and becomes `history` next frame.
layout(rgba16f, set = 1, binding = 2) uniform image2D history;
layout(rgba16f, set = 1, binding = 3) uniform image2D history_write;
//Validation depth: the surface depth each estimate was accumulated for; a delta beyond
//depth_threshold = disocclusion -> reject the stored estimate.
layout(r32f, set = 1, binding = 4) uniform image2D history_depth;
layout(r32f, set = 1, binding = 5) uniform image2D history_depth_write;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
	float accumulation_weight;
	float history_valid;
	float reprojection_enabled;
	float depth_threshold;
	float bilinear_reprojection;
} params;


#include "includes/common.glsl"
#include "includes/albedo.glsl"
#include "includes/disocclusion.glsl"

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

	//EMA: blend current GI into `history` (weight 1 - 0.05^(1/N); N=1 -> no accumulation).
	//history_valid = 0 on the first frame so uninitialized memory is never read.
	//Reprojection: read at the world point's previous-frame position, write at uv into the
	//other ping-pong slot, so shifted reads in other invocations never race this write
	//(a barrier can't span invocations).
	float raw_depth = texture(depth_image, uv).r;
	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);
	vec2 prev_px = vec2(uv) + 0.5;
	float history_valid = params.history_valid;
	float d_exp = depth;
	if(params.reprojection_enabled > 0.5) {
		bool in_bounds;
		get_reprojected_px(
			texture(velocity_tex, uv_center).xy,
			scene.data.inv_projection_matrix, scene.data.inv_view_matrix,
			scene.prev_data.projection_matrix, scene.prev_data.view_matrix,
			uv_center, raw_depth, size, prev_px, in_bounds, d_exp);
		if(!in_bounds) {
			//Previous position off-screen: no valid history for this pixel.
			history_valid = 0.0;
		}
	}
	vec4 acc = GI;
	if(history_valid > 0.5) {
		//Bilinear: 4 taps at the fractional prev_px (texel-center space); the clamp keeps the +1 taps
		//in bounds. Nearest (toggle off) would quantize sub-texel motion to 0/1-texel jumps.
		vec2 q = prev_px - 0.5;
		ivec2 b = clamp(ivec2(floor(q)), ivec2(0), size - 2);
		vec2 f = q - vec2(b);
		vec4 hist;
		float stored_depth;
		if(params.bilinear_reprojection > 0.5) {
			hist = mix(
				mix(imageLoad(history, b), imageLoad(history, b + ivec2(1, 0)), f.x),
				mix(imageLoad(history, b + ivec2(0, 1)), imageLoad(history, b + ivec2(1, 1)), f.x),
				f.y);
			stored_depth = mix(
				mix(imageLoad(history_depth, b), imageLoad(history_depth, b + ivec2(1, 0)), f.x),
				mix(imageLoad(history_depth, b + ivec2(0, 1)), imageLoad(history_depth, b + ivec2(1, 1)), f.x),
				f.y).r;
		} else {
			ivec2 rpv = ivec2(prev_px);
			hist = imageLoad(history, rpv);
			stored_depth = imageLoad(history_depth, rpv).r;
		}
		//Soft rejection: past the motion-compensated tolerance, blend toward fresh in proportion
		//to the excess (full fresh at 2x tolerance) instead of a hard reset.
		float w = max(params.accumulation_weight, disocclusion_staleness(stored_depth, depth, d_exp));
		acc = mix(hist, GI, w);
	}
	imageStore(history_write, uv, acc);
	//Store this surface's depth for next frame's revalidation (unconditional: the estimate converges to the current surface).
	imageStore(history_depth_write, uv, vec4(depth));

	vec3 albedo = get_albedo_modulation(uv, color);

	imageStore(color_image, uv, vec4(mix(color + albedo * acc.rgb, vec3(0), acc.a), 1.0));
}
