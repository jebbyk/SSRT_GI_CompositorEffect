#[compute]
#version 450

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
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;

// Set 1
layout(set = 1, binding = 0, std140) uniform SSRTDataBlock {
	SSRTData data;
} settings;
layout(set = 1, binding = 1) uniform sampler2DArray face_depth_array;
layout(set = 1, binding = 2) uniform sampler2DArray face_color_array;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;

//3x2 grid: cells 0..4 are the faces by layer index, cell 5 the live main view.
//The tint marks the cell border: red=right, green=left, blue=up, yellow=down,
//magenta=back, white=main.
vec3 cell_tint(int cell) {
	if(cell == 0) return vec3(1.0, 0.25, 0.25);
	if(cell == 1) return vec3(0.25, 1.0, 0.25);
	if(cell == 2) return vec3(0.35, 0.55, 1.0);
	if(cell == 3) return vec3(1.0, 1.0, 0.25);
	if(cell == 4) return vec3(1.0, 0.25, 1.0);
	return vec3(1.0);
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec2 norm = vec2(uv) / vec2(size);
	vec2 cell_uv = vec2(fract(norm.x * 3.0), fract(norm.y * 2.0));
	//Grid row 0 = bottom, matching the texture v-up convention.
	int cell = clamp(int(norm.x * 3.0), 0, 2) + (norm.y < 0.5 ? 0 : 3);

	vec3 outc;
	if(cell == 5) {
		outc = imageLoad(color_image, uv).rgb;
	}
	else if(settings.data.offscreen_enabled > 0.5 && (int(settings.data.face_mask) & (1 << cell)) != 0) {
		//Color modulated by the side's captured linear depth (log-normalized against
		//far_plane: near = dark, far = bright, sky = white — same convention as the
		//DEPTH view). Pure black = texel never written (depth 0).
		int fsize = int(settings.data.face_size);
		ivec2 ftex = clamp(ivec2(cell_uv * float(fsize)), ivec2(0), ivec2(fsize - 1));
		float d = texelFetch(face_depth_array, ivec3(ftex, cell), 0).r;
		float ramp = clamp(log(1.0 + max(d, 0.0)) / log(1.0 + settings.data.far_plane), 0.0, 1.0);
		outc = textureLod(face_color_array, vec3(cell_uv, float(cell)), 0.0).rgb * ramp;
	}
	else {
		outc = vec3(0.03);
	}

	//~2px border tint identifies the cell in the raster.
	if(cell_uv.x * float(size.x) / 3.0 < 2.0 || (1.0 - cell_uv.x) * float(size.x) / 3.0 < 2.0
	   || cell_uv.y * float(size.y) / 2.0 < 2.0 || (1.0 - cell_uv.y) * float(size.y) / 2.0 < 2.0) {
		outc = cell_tint(cell);
	}

	imageStore(color_image, uv, vec4(outc, 1.0));
}
