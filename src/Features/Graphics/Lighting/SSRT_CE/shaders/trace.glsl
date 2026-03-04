#[compute]
#version 450

#include "includes/scene_data.glsl"

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

	int blur_kernel_size;
	int blur_steps;

	bool depth_affect_ray_length;
	bool back_face_lighting;
};

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
layout(set = 1, binding = 0, std140) uniform SSRTDataBlock {
	SSRTData data;
} settings;

// Set 2
layout(rgba16f, set = 2, binding = 1) uniform image2D out_image;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;


const float PI = 3.14;

float rand(vec2 uv)
{
	return fract(sin(dot(uv.xy ,vec2(12.9898,78.233))) * 43758.5453);	
}

vec3 rand3d(vec2 uv)
{
	return vec3(
		rand(uv + vec2(0.1245, 0.2935) * vec2(1.3347, 1.90734)),
		rand(uv + vec2(0.3679, 0.86735) * vec2(1.986732, 1.347)),
		rand(uv + vec2(0.9374, 0.71653) * vec2(1.98467, 1.1903))
	);
}

vec3 randomSpherePoint(vec3 rand) {
  float ang1 = (rand.x + 1.0) * PI; // [-1..1) -> [0..2*PI)
  float u = rand.y; // [-1..1), cos and acos(2v-1) cancel each other out, so we arrive at [-1..1)
  float u2 = u * u;
  float sqrt1MinusU2 = sqrt(1.0 - u2);
  float x = sqrt1MinusU2 * cos(ang1);
  float y = sqrt1MinusU2 * sin(ang1);
  float z = u;
  return vec3(x, y, z);
}

vec3 randomHemispherePoint(vec3 rand, vec3 n) {
  vec3 v = randomSpherePoint(rand);
  return v * sign(dot(v, n));
}

bool inScreen(vec2 coord, vec2 size)
{
	return coord.x > 0.0 && coord.x < size.x &&
		coord.y > 0.0 && coord.y < size.y;
}

vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	
	//return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
	vec4 nr = vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0), roughness);
	nr.gb = -nr.gb;
	return nr;
	//return vec4(p_normal_roughness.xyz, 1.0);
}

float get_linear_depth(ivec2 uv)
{
	float depth = imageLoad(depth_image, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	vec4 view = scene.data.inv_projection_matrix * vec4(ndc, 1.0);
	view.xyz /= view.w;

	return -view.z;
}

//The code we want to execute in each invocation
void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	
	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec3 color = imageLoad(color_image, uv).rgb;
	
	float depth = get_linear_depth(uv);

	imageStore(out_image, uv, vec4(0, 0, 0, 1));
	if(depth > settings.data.far_plane) {return;}
	
	vec3 normal = normal_roughness_compatibility(imageLoad(normal_roughness_image, uv)).xyz;

	vec2 centredTexCoord = vec2(uv)/vec2(size) - 0.5;

	vec4 GI = vec4(0);


	float _rayLength = settings.data.ray_length;
	if(settings.data.depth_affect_ray_length){
		_rayLength *= depth;
	}

	float stepLength = _rayLength / settings.data.steps_per_ray;

	stepLength += (rand(scene.data.time * 0.01 * vec2(uv)/vec2(size)) - 0.5) * stepLength;

	float aspectRatio = vec2(size).y / vec2(size).x;

	for(float i = 1.0; i < settings.data.rays_amount + 1.0; i += 1.0){
		vec3 rayStart = vec3(
			centredTexCoord.x * depth,
			centredTexCoord.y * depth,
			depth
		);

		vec3 probePosition = rayStart;

		vec3 rand3d = (rand3d(vec2(uv)/vec2(size) + vec2(i * scene.data.time * 0.001)) - vec3(0.5)) * 2.0;
		vec3 probeDirection = randomHemispherePoint(rand3d, normal) * vec3(aspectRatio, 1.0, 1.0);

		vec3 probeStep = probeDirection * stepLength;
		
		for(float j = 1.0; j < settings.data.steps_per_ray + 1.0; j += 1.0){
			probePosition += probeStep;

			vec2 newUvCoord = probePosition.xy / probePosition.z + vec2(0.5);

			if(!inScreen(ivec2(newUvCoord * vec2(size)), size)) {
				GI.rgb += settings.data.sky_color.rgb * settings.data.sky_color_intensity;
				break;
			}

			float probeTestDepth = get_linear_depth(ivec2(newUvCoord * vec2(size)));//slightly differs

			if(probePosition.z > probeTestDepth && probePosition.z < probeTestDepth + settings.data.z_thickness) {
				GI.a += 1.0;
				vec3 probeTestNormal = normal_roughness_compatibility(imageLoad(normal_roughness_image, ivec2(newUvCoord * vec2(size)))).xyz;
				if(!settings.data.back_face_lighting) {
					if(dot(probeTestNormal, probeDirection) > 0.0) {
						break;
					}
				}
				vec3 probeTestColor = imageLoad(color_image, ivec2(newUvCoord * vec2(size))).rgb;
				GI.rgb += probeTestColor;
				break;
			}
		}
	}

	GI /= settings.data.rays_amount;
	GI.rgb *= settings.data.bounce_intensity * 10.0;
	GI.a *= settings.data.occlusion_intensity * 0.2;

	imageStore(out_image, uv, GI);
}

