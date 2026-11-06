//Shared declarations for mix_box8.glsl / mix_box16f.glsl, spliced in the entry after
//ALBEDO_GI, HISTORY_SCALED and the format-specific `history` / `history_write`
//image3D pair, and before the shared helper includes.
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
	float bilinear_reprojection;
} params;
