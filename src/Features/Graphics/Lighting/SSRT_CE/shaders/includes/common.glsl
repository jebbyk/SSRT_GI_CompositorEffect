//Shared helper for the SSRT compute shaders, spliced in via #include.
//The including shader must declare `scene` (SceneDataBlock) and `depth_image`
//before the #include line.
float get_linear_depth(ivec2 uv)
{
	float depth = imageLoad(depth_image, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	vec4 view = scene.data.inv_projection_matrix * vec4(ndc, 1.0);
	view.xyz /= view.w;

	return -view.z;
}
