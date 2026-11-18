//GI debug: the TEMPORALLY ACCUMULATED bounce — the same history the mix pass composites
//from (EMA: this frame's history write slot; BOX: average of the valid slices).
//0.03125 gray base + 4x Reinhard-compressed raw per-ray bounce, color kept, darkened by
//the accumulated AO (x(1-occ), as in the composite). The trace's bounce/occlusion
//intensity scales are divided out; no albedo/lit-color modulation, no fog. Sky pixels
//are black (history is never written there). Runs AFTER trace/blur/mix.

#[compute]
#version 450

#include "includes/scene_data.glsl"

//SSRTData must stay byte-identical to trace.glsl (shared UBO).
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
	float normal_treshold;
	float blur_normal_treshold;
	float blur_plane_treshold;

	int blur_kernel_size;
	int blur_steps;

	bool depth_affect_ray_length;
	bool back_face_lighting;

	float offscreen_enabled;
	float face_mask;
	float face_size;
};

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
layout(rgba16f, set = 1, binding = 0) uniform image2D in_image;
layout(set = 1, binding = 1, std140) uniform SSRTDataBlock {
	SSRTData data;
} settings;
//Accumulated sources; the unused one stays on a placeholder (samplers are
//format-agnostic, so RGBA8/16F placeholders bind fine and are never read).
layout(set = 1, binding = 2) uniform sampler2D ema_hist;
layout(set = 1, binding = 3) uniform sampler3D box_hist;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
	float accum_mode;     //0 = EMA, 1 = BOX, 2 = no history (per-frame buffer)
	float box_count;      //valid BOX slices
	float box_scale;      //BOX8 stores rgb x1/8 -> decode x8; BOX16F x1
	float pad0;
} params;

#include "includes/common.glsl"

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {
		//Sky: no GI is added there.
		imageStore(color_image, uv, vec4(0.0, 0.0, 0.0, 1.0));
		return;
	}

	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);
	vec4 GI;
	if(params.accum_mode < 0.5) {
		GI = textureLod(ema_hist, uv_center, 0.0);
	}
	else if(params.accum_mode < 1.5) {
		vec4 sum = vec4(0.0);
		for(int i = 0; i < 64; i++) {
			if(i >= int(params.box_count)) {
				break;
			}
			sum += textureLod(box_hist, vec3(uv_center, float(i)), 0.0);
		}
		GI = sum / max(params.box_count, 1.0);
		GI.rgb *= params.box_scale;
	}
	else {
		GI = imageLoad(in_image, uv);
	}

	//Normalize back to raw per-ray units (guard the knobs' zero values).
	vec3 bounce_rgb = GI.rgb / max(settings.data.bounce_intensity * 10.0, 0.0001);
	//Accumulated AO: history alpha is hits/rays x occlusion_intensity x 0.2 -> raw [0,1].
	float ao = GI.a / max(settings.data.occlusion_intensity * 0.2, 0.0001);
	//Bounce: 0.03125 gray base + 4x Reinhard-compressed bounce (b/(1+b) maps [0,inf)
	//into [0,1) so sunlit linear-HDR values stay readable), then darkened by AO with
	//the same (1 - occlusion) the mix composite applies. x0.45 keeps the result in the
	//scene tonemapper's linear region.
	vec3 compressed = bounce_rgb / (vec3(1.0) + bounce_rgb);
	vec3 signal = clamp(vec3(0.03125) + 2.0 * compressed, vec3(0.0), vec3(1.0)) * (1.0 - clamp(ao, 0.0, 1.0));
	imageStore(color_image, uv, vec4(0.45 * signal, 1.0));
}
