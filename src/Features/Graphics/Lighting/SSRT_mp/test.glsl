#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;

//The code we want to execute in each invocation
void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);


	vec3 color = imageLoad(color_image, uv).rgb;

	float gray = color.r + color.g + color.b;
	gray /= 3.0;
	
	imageStore(color_image, uv,  vec4(vec3(gray), 1.0));
}
