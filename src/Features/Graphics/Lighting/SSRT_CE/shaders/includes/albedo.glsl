//Albedo modulation for the mix passes, spliced via #include. Includers must declare
//ALBEDO_GI, params (raster_size/albedo_size) and albedo_texture before the #include.
//Returns the scene's unlit albedo (SSRTAlbedoSource) when available, else the
//already-lit fallback — so directly-lit surfaces are not overbrightened.
vec3 get_albedo_modulation(ivec2 uv, vec3 fallback_color)
{
	if(ALBEDO_GI && params.albedo_size.x > 0.0 && params.albedo_size.y > 0.0) {
		//Normalize by raster_size (the size uv spans), not the albedo texture's own size.
		vec2 albedo_uv = vec2(uv) / params.raster_size;
		return texture(albedo_texture, albedo_uv).rgb;
	}
	return fallback_color;
}
