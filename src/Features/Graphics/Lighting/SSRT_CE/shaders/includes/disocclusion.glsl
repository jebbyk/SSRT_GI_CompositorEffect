//Soft disocclusion rejection weight, shared by the EMA and box mix passes.
//d_exp = the tracked point's depth under the previous camera; a depth change it
//explains is not counted as staleness. Returns 0.0 (fully fresh) .. 1.0 (fully
//stale, at 2x tolerance). depth_threshold <= 0 disables (returns 0.0).
float disocclusion_staleness(float stored_depth, float depth, float d_exp)
{
	if(params.depth_threshold <= 0.0) {
		return 0.0;
	}
	float delta = abs(stored_depth - depth);
	float tol = params.depth_threshold * max(stored_depth, depth) + abs(d_exp - depth);
	if(delta <= tol) {
		return 0.0;
	}
	return min((delta - tol) / tol, 1.0);
}
