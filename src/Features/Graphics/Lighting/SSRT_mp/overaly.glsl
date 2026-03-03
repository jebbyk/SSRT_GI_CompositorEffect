#version 450

layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(rgba16f, set = 0, binding = 2) uniform image2D gi_image;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(params.raster_size);

    if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

    vec3 color = imageLoad(color_image, uv).rgb;
    vec4 GI = imageLoad(gi_image, uv);

    imageStore(color_image, uv, vec4(mix(color + color * GI.rgb), vec4(0), GI.a), 1.0);
}