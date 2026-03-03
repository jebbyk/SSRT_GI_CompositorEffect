shader_type spatial;
render_mode
unshaded
//,blend_add
//,blend_mix
//,blend_mul
//,blend_sub
//,blend_premul_alpha
;



varying mat4 CAMERA;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform	float offset : hint_range(0.0, 3.0);


void vertex() {
	//CAMERA = INV_VIEW_MATRIX;
	//POSITION = vec4(VERTEX, 1.0);
	 POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 tl = texture(screen_texture, SCREEN_UV).rgb;
	vec3 tr = texture(screen_texture, SCREEN_UV  + vec2(offset / VIEWPORT_SIZE.x,0)).rgb;
	vec3 bl = texture(screen_texture, SCREEN_UV  + vec2(0 ,offset / VIEWPORT_SIZE.y)).rgb;
	vec3 br = texture(screen_texture, SCREEN_UV  + vec2(offset / VIEWPORT_SIZE.x ,offset / VIEWPORT_SIZE.y)).rgb;

	ALBEDO = (tl + tr + bl + br) / 4.0f;
}