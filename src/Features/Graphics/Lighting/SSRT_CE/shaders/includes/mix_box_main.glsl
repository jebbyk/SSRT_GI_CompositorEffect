//Shared main() of mix_box8.glsl / mix_box16f.glsl. Requires the entry's
//HISTORY_SCALED and format-specific `history` / `history_write` pair, the
//mix_box_decl declarations, and the common/albedo/disocclusion helpers.

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if(uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	float depth = get_linear_depth(uv);
	if(depth > 1000.0) {return;}

	vec3 color = imageLoad(color_image, uv).rgb;

	vec4 GI = imageLoad(in_image, uv);

	//1/8 UNORM RGB encode/decode scale for the HISTORY_SCALED entry; 1.0 for the full-float entry.
	float hist_scale = HISTORY_SCALED ? 8.0 : 1.0;

	//Flat N-frame average over the rolling window (slot = frame % N).
	//Reprojection on: each slot is shifted into the current frame's screen space
	//(reads at prev_px, writes at uv), so all slices track the current point.
	//Reprojection off: plain per-uv box average.
	float raw_depth = texture(depth_image, (vec2(uv) + 0.5) / params.raster_size).r;
	vec2 uv_center = (vec2(uv) + 0.5) / vec2(size);
	vec2 p = vec2(uv) + 0.5;
	vec2 prev_px = p;
	bool reproj = params.reprojection_enabled > 0.5;
	float d_exp = depth;
	if(reproj) {
		bool in_bounds;
		get_reprojected_px(
			texture(velocity_tex, uv_center).xy,
			scene.data.inv_projection_matrix, scene.data.inv_view_matrix,
			scene.prev_data.projection_matrix, scene.prev_data.view_matrix,
			uv_center, raw_depth, size, prev_px, in_bounds, d_exp);
	}
	vec4 fresh = vec4(GI.rgb / hist_scale, GI.a);
	int sc = int(params.valid_count);
	int s = int(params.slot_index);
	vec4 acc = GI;
	if(reproj) {
		bool rp_ok = prev_px.x >= 0.5 && prev_px.y >= 0.5
			&& prev_px.x <= float(size.x) - 0.5 && prev_px.y <= float(size.y) - 0.5;
		//Nearest tap; the bilinear toggle uses the fractional taps instead.
		ivec2 rpv = ivec2(prev_px);
		//4-tap bilinear taps at the fractional prev_px (texel-center space), shared by all slots;
		//the clamp keeps the +1 taps in bounds.
		vec2 q = prev_px - 0.5;
		ivec2 b = clamp(ivec2(floor(q)), ivec2(0), size - 2);
		vec2 f = q - vec2(b);
		vec4 sum = vec4(0.0);
		for(int i = 0; i < sc; i++) {
			vec4 v;
			if(i == s) {
				v = fresh;
			} else {
				//Soft rejection: blend the slot toward fresh in proportion to its
				//disocclusion staleness (full fresh at 2x tolerance).
				float w_stale = 1.0;
				vec4 hist = fresh;
				if(rp_ok) {
					w_stale = 0.0;
					float stored_depth;
					if(params.bilinear_reprojection > 0.5) {
						hist = mix(
							mix(imageLoad(history, ivec3(b, i)), imageLoad(history, ivec3(b + ivec2(1, 0), i)), f.x),
							mix(imageLoad(history, ivec3(b + ivec2(0, 1), i)), imageLoad(history, ivec3(b + ivec2(1, 1), i)), f.x),
							f.y);
						stored_depth = mix(
							mix(imageLoad(history_depth, ivec3(b, i)), imageLoad(history_depth, ivec3(b + ivec2(1, 0), i)), f.x),
							mix(imageLoad(history_depth, ivec3(b + ivec2(0, 1), i)), imageLoad(history_depth, ivec3(b + ivec2(1, 1), i)), f.x),
							f.y).r;
					} else {
						hist = imageLoad(history, ivec3(rpv, i));
						stored_depth = imageLoad(history_depth, ivec3(rpv, i)).r;
					}
					w_stale = disocclusion_staleness(stored_depth, depth, d_exp);
					v = w_stale >= 1.0 ? fresh : mix(hist, fresh, w_stale);
				} else {
					v = fresh;
				}
				imageStore(history_write, ivec3(uv, i), v);
				//Re-seed the depth fingerprint to the current frame each pass: the check then compares
				//1-frame-apart depths (not i-frame-apart), so old slots are not false-rejected by camera motion.
				imageStore(history_depth_write, ivec3(uv, i), vec4(depth));
			}
			sum += v;
		}
		imageStore(history_write, ivec3(uv, s), fresh);
		imageStore(history_depth_write, ivec3(uv, s), vec4(depth));
		acc = sum / float(sc);
	} else {
		imageStore(history, ivec3(uv, s), fresh);
		imageStore(history_depth, ivec3(uv, s), vec4(depth));
		vec4 sum = vec4(0.0);
		for(int i = 0; i < sc; i++) {
			if(i == s) {
				sum += fresh;
			} else {
				//uv is always in bounds here (checked above), no rp_ok needed.
				float stored_depth = imageLoad(history_depth, ivec3(uv, i)).r;
				bool slot_ok = params.depth_threshold <= 0.0
					|| abs(stored_depth - depth) <= params.depth_threshold * max(stored_depth, depth);
				sum += slot_ok ? imageLoad(history, ivec3(uv, i)) : fresh;
			}
		}
		acc = sum / float(sc);
	}
	acc.rgb *= hist_scale; //decode the entry's UNORM RGB scale (no-op for the full-float entry)

	vec3 albedo = get_albedo_modulation(uv, color);

	//Fog-aware composite: GI and occlusion act in unfogged space, then the pixel is refogged.
	vec4 fog = get_fog_scatter_and_transmittance(uv);
	float occlusion = clamp(acc.a, 0.0, 1.0);
	imageStore(color_image, uv, vec4((color + albedo * acc.rgb * fog.a) * (1.0 - occlusion) + fog.rgb * occlusion, 1.0));
}
