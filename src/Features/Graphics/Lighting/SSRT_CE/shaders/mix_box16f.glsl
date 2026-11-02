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
//Engine velocity buffer (needs_motion_vectors): per-object screen-space delta
//in UV units, preferred by get_reprojected_px over the camera-only path.
layout(set = 0, binding = 4) uniform sampler2D velocity_tex;

// Set 1
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;
//Combined image+sampler (matches UNIFORM_TYPE_SAMPLER_WITH_TEXTURE in SSRT_CE.gd).
layout(set = 1, binding = 1) uniform sampler2D albedo_texture;
//N-frame RGBA16F history (depth = N): full float, HDR RGB + AO, no encoding.
layout(rgba16f, set = 1, binding = 2) uniform image3D history;
//Ping-pong write partner of `history`, touched only when reprojection is on:
//the pass shifts the slots into this frame's screen space there, then the two
//textures are swapped after the pass. With reprojection off both bindings
//carry the same single texture and only `history` is used.
layout(rgba16f, set = 1, binding = 3) uniform image3D history_write;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 albedo_size;
	float slot_index;
	float valid_count;
	float reprojection_enabled;
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

	//Flat N-frame average over the rolling window (slot = frame % N). With
	//reprojection the history is kept aligned: each frame every slot is shifted
	//into the previous frame's screen space by the 1-frame MV (shifted copies
	//go to history_write, the textures are swapped after the pass), so all
	//slices are read at prev_px — exact for any camera motion, no velocity
	//assumption. A pixel whose previous position is off-screen (newly exposed)
	//has no valid shifted copies and resets its slots to the fresh capture.
	//Without reprojection both bindings carry one texture and the slots are
	//read/written at uv (the plain box average).
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
	vec4 fresh = GI;
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
				if(rp_ok) {
					v = imageLoad(history, ivec3(rpv, i));
				} else {
					v = fresh;
				}
				imageStore(history_write, ivec3(uv, i), v);
			}
			sum += v;
		}
		imageStore(history_write, ivec3(uv, s), fresh);
		acc = sum / float(sc);
	} else {
		imageStore(history, ivec3(uv, s), fresh);
		vec4 sum = vec4(0.0);
		for(int i = 0; i < sc; i++) {
			sum += imageLoad(history, ivec3(uv, i));
		}
		acc = sum / float(sc);
	}

	//When enabled, modulate the GI bounce by the scene's unlit albedo (rendered
	//by SSRTAlbedoSource) instead of the already-lit color, so directly-lit
	//surfaces are not overbrightened. Falls back to the legacy lit-color
	//modulation when ALBEDO_GI is off or the albedo size is not available.
	vec3 albedo = get_albedo_modulation(uv, color);

	imageStore(color_image, uv, vec4(mix(color + albedo * acc.rgb, vec3(0), acc.a), 1.0));
}
