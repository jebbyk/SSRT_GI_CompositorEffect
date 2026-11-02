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
//Engine velocity buffer: per-object screen-space delta in UV units; preferred over the camera-only path.
layout(set = 0, binding = 4) uniform sampler2D velocity_tex;

// Set 1
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;
//Combined image+sampler (matches UNIFORM_TYPE_SAMPLER_WITH_TEXTURE in SSRT_CE.gd).
layout(set = 1, binding = 1) uniform sampler2D albedo_texture;
//N-frame RGBA8 history. RGB stored *1/8 (trace output lives in ~0..8; the 8-bit step
//~0.031 is below per-frame ray noise). Above 8 clips. AO in 0..1 as-is.
layout(rgba8, set = 1, binding = 2) uniform image3D history;
//Ping-pong write partner, used only with reprojection on (slots are shifted there,
//textures swapped after the pass). Reprojection off: both bindings are the same texture.
layout(rgba8, set = 1, binding = 3) uniform image3D history_write;
//Per-slot validation depth (r32f, same N slices), ping-ponged in lockstep:
//the surface depth each slot was captured from.
layout(r32f, set = 1, binding = 4) uniform image3D history_depth;
layout(r32f, set = 1, binding = 5) uniform image3D history_depth_write;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
	float slot_index;
	float valid_count;
	float reprojection_enabled;
	float depth_threshold;
} params;


#include "includes/common.glsl"
#include "includes/albedo.glsl"

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

	//Flat N-frame average over the rolling window (slot = frame % N).
	//Reprojection on: each slot is shifted into the current frame's screen space
	//(reads at prev_px, writes at uv), so all slices track the current point.
	//Reprojection off: plain per-uv box average.
	float raw_depth = imageLoad(depth_image, uv).r;
	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);
	vec2 p = vec2(uv) + 0.5;
	vec2 prev_px = p;
	bool reproj = params.reprojection_enabled > 0.5;
	if(reproj) {
		bool in_bounds;
		get_reprojected_px(
			texture(velocity_tex, uv_center).xy,
			scene.data.inv_projection_matrix, scene.data.inv_view_matrix,
			scene.prev_data.projection_matrix, scene.prev_data.view_matrix,
			uv_center, raw_depth, size, prev_px, in_bounds);
	}
	vec4 fresh = vec4(GI.rgb * (1.0 / 8.0), GI.a);
	int sc = int(params.valid_count);
	int s = int(params.slot_index);
	vec4 acc = GI;
	if(reproj) {
		bool rp_ok = prev_px.x >= 0.5 && prev_px.y >= 0.5
			&& prev_px.x <= float(size.x) - 0.5 && prev_px.y <= float(size.y) - 0.5;
		ivec2 rpv = ivec2(prev_px);
		vec4 sum = vec4(0.0);
		for(int i = 0; i < sc; i++) {
			vec4 v;
			if(i == s) {
				v = fresh;
			} else {
				//Disocclusion: slot's stored depth moved beyond the threshold -> stale, reset to fresh.
				bool slot_ok = false;
				float stored_depth = 0.0;
				if(rp_ok) {
					stored_depth = imageLoad(history_depth, ivec3(rpv, i)).r;
					slot_ok = params.depth_threshold <= 0.0
						|| abs(stored_depth - depth) <= params.depth_threshold * max(stored_depth, depth);
				}
				v = slot_ok ? imageLoad(history, ivec3(rpv, i)) : fresh;
				imageStore(history_write, ivec3(uv, i), v);
				//Shift the slot's depth with its capture; seed it on reset.
				imageStore(history_depth_write, ivec3(uv, i), vec4(slot_ok ? stored_depth : depth));
			}
			sum += v;
		}
		imageStore(history_write, ivec3(uv, s), fresh);
		imageStore(history_depth_write, ivec3(uv, s), vec4(depth));
		acc = sum / float(sc);
		acc.rgb *= 8.0; //decode the 1/8 UNORM RGB scale
	} else {
		imageStore(history, ivec3(uv, s), fresh);
		imageStore(history_depth, ivec3(uv, s), vec4(depth));
		vec4 sum = vec4(0.0);
		for(int i = 0; i < sc; i++) {
			if(i == s) {
				sum += fresh;
			} else {
				//uv is always in bounds here (checked above), no rp_ok needed.
				float stored_depth = imageLoad(history_depth, ivec3(uv, i)).r;
				bool slot_ok = params.depth_threshold <= 0.0
					|| abs(stored_depth - depth) <= params.depth_threshold * max(stored_depth, depth);
				sum += slot_ok ? imageLoad(history, ivec3(uv, i)) : fresh;
			}
		}
		acc = sum / float(sc);
		acc.rgb *= 8.0; //decode the 1/8 UNORM RGB scale
	}

	vec3 albedo = get_albedo_modulation(uv, color);

	imageStore(color_image, uv, vec4(mix(color + albedo * acc.rgb, vec3(0), acc.a), 1.0));
}
