extends SceneTree

var _failures := 0


func check(label: String, ok: bool) -> void:
	print(("[PASS] " if ok else "[FAIL] ") + label)
	if not ok:
		_failures += 1


func _init():
	var packed: PackedScene = load("res://test_scene.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	await process_frame
	await process_frame
	await process_frame

	var sub: Node = scene.get_node_or_null("SubViewport")
	check("SubViewport node exists", sub != null)

	var handoff: Resource = sub.get("albedo_handoff") if sub else null
	check("SubViewport.albedo_handoff is set", handoff != null)

	var vp_rid: RID = handoff.get("viewport_rid") if handoff else RID()
	check("handoff.viewport_rid is valid", vp_rid.is_valid())

	var vp_size: Vector2i = handoff.get("albedo_size") if handoff else Vector2i.ZERO
	check("handoff.albedo_size is non-zero", vp_size.x > 0 and vp_size.y > 0)
	print("  handoff.albedo_size = ", vp_size)

	if sub:
		var sub_size: Vector2i = sub.size
		check("SubViewport.size matches handoff size", sub_size == vp_size)
		print("  debug_draw = ", sub.debug_draw, " (expect 1 = UNSHADED)")
		print("  update_mode = ", sub.render_target_update_mode, " (expect 4 = ALWAYS)")
		print("  use_hdr_2d = ", sub.use_hdr_2d)

	#Camera mirroring: pause the animation, move the source, verify the mirror.
	var cam_src: Node = sub.get("camera_source") if sub else null
	check("camera_source resolved to a Camera3D", cam_src is Camera3D)
	# Look the mirror camera up by type, not by name: the user renamed the
	# camera nodes in the scene (Camera3D-free-look / Camera3D-albedo-source).
	var cam_dst: Node = null
	if sub:
		for c in sub.get_children():
			if c is Camera3D:
				cam_dst = c
				break
	check("stub camera inside SubViewport exists", cam_dst is Camera3D)
	if cam_src and cam_dst:
		var ap: Node = cam_src.get_node_or_null("AnimationPlayer")
		if ap:
			(ap as AnimationPlayer).pause()
		var t := Transform3D()
		t.origin = Vector3(10.0, 5.0, -3.0)
		cam_src.global_transform = t
		await process_frame
		await process_frame
		check("camera transform mirrored into SubViewport", cam_dst.global_transform == cam_src.global_transform)

	#Variant B: the SubViewport renders the LIVE main world, so it must NOT hold
	#a duplicated geometry child (the old isolated-world design created a static
	#duplicate — that was the "ghost" bug). Only the mirror camera is allowed as
	#a 3D child of the SubViewport.
	var dup: Node = null
	if sub:
		for c in sub.get_children():
			if c is Node3D and not (c is Camera3D) and not (c is WorldEnvironment):
				dup = c
				break
	check("no duplicate geometry child (variant B renders the live world)", dup == null)

	#The CE must hold the very same handoff instance.
	var ce_handoff: Resource = null
	var we: Node = scene.get_node_or_null("WorldEnvironment")
	if we:
		var comp: Compositor = we.compositor
		if comp:
			for e in comp.get_compositor_effects():
				var h: Resource = e.get("albedo_handoff")
				if h:
					ce_handoff = h
					break
	check("CompositorEffect.albedo_handoff is set", ce_handoff != null)
	check("CE and SubViewport share the same handoff instance", ce_handoff == handoff)

	# ==================================================================
	#  Tester extension: independent assertions + edge cases
	# ==================================================================

	# --- AC2 (strict): the section above only PRINTED these values ---
	check("SubViewport.debug_draw == UNSHADED (1)", sub.debug_draw == Viewport.DEBUG_DRAW_UNSHADED)
	check("SubViewport.render_target_update_mode == ALWAYS (4)", sub.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	check("SubViewport.use_hdr_2d == true", sub.use_hdr_2d == true)

	# --- AC3 (strict): RID identity + the exact resolution chain the CE uses ---
	check("handoff.viewport_rid == SubViewport.get_viewport_rid()", vp_rid == sub.get_viewport_rid())
	var rd = RenderingServer.get_rendering_device()
	print("  RenderingDevice present: ", rd != null, " (headless => null, GPU chain skipped)")
	# NOTE: the CE only calls viewport_get_texture()/texture_get_rd_texture() on the
	# render thread (rd != null). The headless dummy driver does not implement
	# viewport textures (verified: a plain SubViewport also returns invalid there),
	# so this chain is asserted only when a real RenderingDevice exists.
	if rd != null:
		var rs_tex: RID = RenderingServer.viewport_get_texture(vp_rid)
		check("RenderingServer.viewport_get_texture(handoff.viewport_rid) is valid (CE chain step 1)", rs_tex.is_valid())
		var rd_tex: RID = RenderingServer.texture_get_rd_texture(rs_tex, false)
		check("texture_get_rd_texture resolves to a valid RD texture (GPU chain)", rd_tex.is_valid())

	# --- AC4 (strict): camera_source is the sibling Camera3D; mirror is per-frame ---
	var sibling_cam: Node = null
	for c in sub.get_parent().get_children():
		if c is Camera3D:
			sibling_cam = c
			break
	check("camera_source is the sibling main Camera3D", cam_src == sibling_cam)
	if cam_src and cam_dst:
		var t2 := Transform3D(Basis(Vector3.UP, deg_to_rad(45.0)) * Basis(Vector3.RIGHT, deg_to_rad(30.0)), Vector3(-7.0, 12.0, 42.0))
		cam_src.global_transform = t2
		await process_frame
		await process_frame
		check("camera transform re-mirrored after 2nd move with rotation (per-frame mirror)", cam_dst.global_transform == cam_src.global_transform)

	# --- Variant B: NO isolated linear WorldEnvironment inside the SubViewport ---
	# The old design added a linear-tonemap WorldEnvironment child so the isolated
	# world produced a raw albedo. Option B removed it (the main world's
	# environment now applies — documented "Accepted consequence"), so there must
	# be NO WorldEnvironment child of the albedo SubViewport.
	var we_sub: WorldEnvironment = null
	for c in sub.get_children():
		if c is WorldEnvironment:
			we_sub = c
			break
	check("no isolated WorldEnvironment child (variant B: main world env applies)", we_sub == null)

	# --- Edge: SubViewport + handoff follow a window resize (resize path of _process) ---
	var old_size: Vector2i = sub.size
	root.size = Vector2i(old_size.x + 320, old_size.y + 200)
	await process_frame
	await process_frame
	check("SubViewport.size follows root resize", sub.size == root.size)
	check("handoff.albedo_size updated on resize", handoff.get("albedo_size") == root.size)

	# --- Edge: legacy mode — handoff detached from BOTH CE and SubViewport, scene must survive ---
	var ce_ref: CompositorEffect = null
	if we:
		var comp2: Compositor = we.compositor
		if comp2:
			for e in comp2.get_compositor_effects():
				if e.get("albedo_handoff") == handoff:
					ce_ref = e
					break
	check("CE with handoff located for legacy test", ce_ref != null)
	if ce_ref:
		ce_ref.set("albedo_handoff", null)
		check("CE.albedo_handoff round-trips to null", ce_ref.get("albedo_handoff") == null)
		check("detaching handoff marks CE shaders_dirty (legacy recompile scheduled)", ce_ref.get("shaders_dirty") == true)
	sub.set("albedo_handoff", null)
	await process_frame
	await process_frame
	await process_frame
	check("scene survives 3 frames with handoff fully detached (legacy mode)", true)
	check("SubViewport still UNSHADED/ALWAYS/HDR after detach", sub.debug_draw == Viewport.DEBUG_DRAW_UNSHADED
		and sub.render_target_update_mode == SubViewport.UPDATE_ALWAYS and sub.use_hdr_2d == true)

	# --- Edge: a fresh SSRTAlbedoSource (no scene attached) must not crash and must not add stray 3D children ---
	var sub_script: GDScript = load("res://Features/Graphics/Lighting/SSRT_CE/albedo_source_viewport.gd")
	var sub2: SubViewport = sub_script.new()
	root.add_child(sub2)
	await process_frame
	await process_frame
	check("fresh SSRTAlbedoSource (no scene) runs without crash", true)
	var stray_geo := false
	for c in sub2.get_children():
		if c is Node3D and c is not Camera3D:
			stray_geo = true
	check("fresh SSRTAlbedoSource adds no stray 3D child (only its mirror camera)", not stray_geo)
	sub2.queue_free()
	await process_frame

	print("")
	print("RESULT: ", ("FAILED (%d)" % _failures) if _failures > 0 else "ALL CHECKS PASSED")
	quit(1 if _failures > 0 else 0)
