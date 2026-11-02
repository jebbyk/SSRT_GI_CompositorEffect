//Albedo modulation for the mix passes, spliced in via #include.
//The including shader must declare `ALBEDO_GI`, `params` (with raster_size and
//albedo_size) and `albedo_texture` before the #include line.
//Returns the scene's unlit albedo (from SSRTAlbedoSource) when available,
//otherwise the already-lit fallback color (the legacy modulation).
vec3 get_albedo_modulation(ivec2 uv, vec3 fallback_color)
{
	if(ALBEDO_GI && params.albedo_size.x > 0.0 && params.albedo_size.y > 0.0) {
		//Normalize by raster_size (the size uv spans), not the albedo texture's own size.
		vec2 albedo_uv = vec2(uv) / params.raster_size;
		return texture(albedo_texture, albedo_uv).rgb;
	}
	return fallback_color;
}
