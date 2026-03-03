shader_type spatial;
render_mode
unshaded
//,blend_add
//,blend_mix
//,blend_mul
,blend_sub
//,blend_premul_alpha
;

uniform sampler2D depth_texture : source_color, hint_depth_texture;
uniform sampler2D normal_roughness_texture : hint_normal_roughness_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
//
uniform	float raysAmount : hint_range(1,512,1);
uniform	float stepsPerRay : hint_range(1,1024,1);
uniform	float intencity : hint_range(0.01, 10.0);
uniform	float aoIntencity : hint_range(0.01, 10.0);
uniform	float intencityFallof : hint_range(0.0, 2.0);
uniform	float rayLength : hint_range(0.01, 10.0);
uniform bool screenSpaceFixedRayLength = true;
uniform	float depthTreshold : hint_range(0.01, 10.0);
uniform float rayBias : hint_range(0.000, 0.1);
uniform vec4 skyColor : source_color = vec4(0.25, 0.5, 1.0, 1.0);
uniform float skyColorIntencity : hint_range(0.01, 10.0);
uniform bool rayMissToSky = true;
uniform bool backFaceLighting = true;
uniform float farPlane : hint_range(1.0, 1000.0);
uniform int blendMode : hint_range(0,2,1) = 0;
uniform float perspective : hint_range(0.1, 10.0);
uniform sampler2D noiseTexture: filter_linear_mipmap_anisotropic, repeat_enable;
uniform int noiseMode = 0;

varying mat4 CAMERA;

float computeRand(vec2 uv)
{
	return fract(sin(dot(uv.xy ,vec2(12.9898,78.233))) * 43758.5453);	
	//return texture(noiseTexture,uv * 32.0, 0).r * 2.0 - 0.5;
}

float textureRand(vec2 uv)
{
	return textureLod(noiseTexture,uv * 1.0, 0).r * 2.0 - 0.5;
}

float rand(vec2 uv)
{
	return computeRand(uv);
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

float getLinearDepth(vec2 uv, mat4 projMatrix)
{
	float depth = texture(depth_texture, uv).x;
	vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	vec4 view = projMatrix * vec4(ndc, 1.0);
	view.xyz /= view.w;

	return -view.z;
}

vec3 getScreenSpaceNormal(vec2 uv)
{
	vec3 screenSpaceNormal = texture(normal_roughness_texture, uv).xyz;

	return screenSpaceNormal * 2.0 - 1.0;
}

float getRoughness(vec2 uv)
{
	return pow(1.0 - texture(normal_roughness_texture, uv).w, 8.0);
}

bool inScreen(vec2 coord)
{
	return coord.x > 0.0 && coord.x < 1.0 &&
		coord.y > 0.0 && coord.y < 1.0;
}

bool outOfScreen(vec2 coord)
{
	return coord.x < 0.0 || coord.x > 1.0 ||
		coord.y < 0.0 || coord.y > 1.0;
}

void vertex() {
	//CAMERA = INV_VIEW_MATRIX;
	//POSITION = vec4(VERTEX, 1.0);
	 POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = texture(screen_texture, SCREEN_UV).rgb;

	float depth = getLinearDepth(SCREEN_UV, INV_PROJECTION_MATRIX);
	
	//if(depth > farPlane) {discard;}

	vec3 normal = getScreenSpaceNormal(SCREEN_UV) * vec3(1.0,-1.0,-1.0);

	//float reflected = getRoughness(SCREEN_UV);

	vec2 centredTexCoord = SCREEN_UV - 0.5;

	vec3 GI = vec3(0);
	float GIAO = 0.0f;

	float _rayLength = rayLength;
	if(screenSpaceFixedRayLength){
		_rayLength *= depth;
	}

	float stepLength = _rayLength / stepsPerRay;

	stepLength += (rand(TIME * 0.001 * SCREEN_UV) - 0.5) * stepLength;

	//vec3 _skyColor = skyColor.rgb * skyColorIntencity;
	//vec3 _skyColorM = _skyColor * 0.25;
//
	float aspectRatio = VIEWPORT_SIZE.y / VIEWPORT_SIZE.x;
	
	for(float i = 1.0; i < raysAmount + 1.0; i += 1.0){
		vec3 probePosition = vec3(
			centredTexCoord.x * depth * perspective,
			centredTexCoord.y * depth * perspective,
			depth
		);
		
		probePosition += normal * rayBias * depth;

		vec3 rand3d = (rand3d(SCREEN_UV + vec2(i * TIME * 0.0001, i * TIME * 0.0001)) - vec3(0.5)) * 2.0;
		vec3 probeDirection = randomHemispherePoint(rand3d, normal) * vec3(aspectRatio, 1.0, 1.0);

		////vec3 probeDirectionReflected = reflect(probePosition, normal);
	
		////vec3 probeDirection = mix(probeDirectionDiffused, probeDirectionReflected, reflected);

		vec3 probeStep = probeDirection * stepLength;
		
		//vec3 probeStep = probeDirectionDiffused * stepLength;
		//
//
		for(float j = 1.0; j < stepsPerRay + 1.0; j += 1.0){
			probePosition += probeStep;
		
			vec2 newUvCoord = probePosition.xy / probePosition.z + vec2(0.5);
			//ALBEDO = ALBEDO - vec3(newUvCoord, 0.0);	

			if(!inScreen(newUvCoord)) {
				//GI += _skyColor;
				//ALBEDO = -ALBEDO;
				break;
			}

			float probeTestDepth = getLinearDepth(newUvCoord, INV_PROJECTION_MATRIX);
			//ALBEDO = ALBEDO - vec3(probeTestDepth) * 0.01;	
			if(probePosition.z > probeTestDepth && probePosition.z < probeTestDepth + depthTreshold) {
				GIAO += 10.0;
				////ALBEDO = ALBEDO - vec3(1.0);
				vec3 probeTestNormal = getScreenSpaceNormal(newUvCoord).xyz * vec3(1.0, -1.0, -1.0);
				
//
				if(!backFaceLighting) {
					if(dot(probeTestNormal, probeDirection) > 0.0) {
						break;
					}
				}
////
				vec3 probeTestColor = texture(screen_texture, newUvCoord).rgb;
////
				ALBEDO = ALBEDO - probeTestColor;

				////GI += probeTestColor;
				////
				////break;
			}
		}
////
		////if(rayMissToSky){
			////GI += _skyColorM;
		////}
	}
//
	////GI /= raysAmount;
	////GI *= intencity * 0.1;
	////
	////GIAO /= raysAmount;
	////GIAO *= aoIntencity * 0.025;

	//ALBEDO = (GIAO*ALBEDO) -(GI * ALBEDO) * 50.0;


	//ALBEDO = ALBEDO - normal;
	 //ALBEDO = ALBEDO - vec3(depth * 0.01) * normal;
	//ALBEDO = ALBEDO - vec3(aspectRatio) * 0.1;
}