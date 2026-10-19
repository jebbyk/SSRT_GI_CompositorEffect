extends SceneTree
# Round 4 verification (sizing) + Option B (live-world albedo):
#   B1 - CE-driven sizing branch of SSRTAlbedoSource._target_size()
#        (handoff.render_size published by the CE has priority over the
#         root.size fallback)
#   B2 - CE render_size == ZERO => root.size fallback branch still works
#   B3 - albedo SubViewport SHARES the principal world (Option B: no isolated
#        own World3D, RID EQUAL to the principal world). This is the "no ghost"
#        fix — the old isolated-world isolation is intentionally gone.
# In headless RenderingServer.get_rendering_device() == null, so the CE render
# callback never runs and nobody writes handoff.render_size — B1 emulates the
# CE publish by writing handoff.render_size directly (same cross-thread write
# the CE performs).
# B4/B5 (file-level greps) are executed outside this script via bash.

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

	var sub: SubViewport = scene.get_node_or_null("SubViewport")
	check("SubViewport node exists", sub != null)
	if not sub:
		_finish()
		return

	var handoff: Resource = sub.get("albedo_handoff")
	check("SubViewport.albedo_handoff is set", handoff != null)
	if not handoff:
		_finish()
		return

	# In headless the CE never published a size, so render_size must still be
	# zero before we emulate the publish — otherwise B1 would be testing
	# against pre-existing CE state, not against our write.
	check("precondition: handoff.render_size is ZERO before CE emulation", handoff.render_size == Vector2i.ZERO)
	# The fallback branch returns root.size; make sure the emulated CE value
	# is unambiguous (not vacuously equal to the fallback).
	check("precondition: root.size != (512,384) so the CE value is distinguishable", root.size != Vector2i(512, 384))
	print("  pre-CE SubViewport.size = ", sub.size, " root.size = ", root.size)

	# ------------------------------------------------------------------
	# B1: CE-driven sizing (new branch, priority over root.size fallback)
	# ------------------------------------------------------------------
	handoff.render_size = Vector2i(512, 384)
	await process_frame
	await process_frame
	await process_frame
	check("B1: SubViewport.size follows CE-published render_size (512x384)", sub.size == Vector2i(512, 384))
	print("  B1 SubViewport.size = ", sub.size)
	check("B1: handoff.albedo_size == CE render_size", handoff.albedo_size == Vector2i(512, 384))
	check("B1: CE size has priority over root.size fallback", sub.size == Vector2i(512, 384) and sub.size != root.size)

	# ------------------------------------------------------------------
	# B2: CE size zero => fallback to root.size
	# ------------------------------------------------------------------
	handoff.render_size = Vector2i.ZERO
	await process_frame
	await process_frame
	await process_frame
	check("B2: SubViewport.size falls back to root.size when CE size is zero", sub.size == root.size)
	print("  B2 SubViewport.size = ", sub.size, " root.size = ", root.size)
	check("B2: handoff.albedo_size follows the fallback size", handoff.albedo_size == root.size)

	# ------------------------------------------------------------------
	# B3: Option B — the albedo SubViewport SHARES the principal world
	# (the "no ghost" fix; the old isolated-world design is intentionally gone)
	# ------------------------------------------------------------------
	check("B3: SubViewport does NOT use its own World3D (variant B: shares main world)", sub.is_using_own_world_3d() == false)
	var sub_world: RID = sub.find_world_3d()
	check("B3: sub.find_world_3d() is valid", sub_world.is_valid())
	var root_world: RID = root.find_world_3d()
	check("B3: root.find_world_3d() is valid", root_world.is_valid())
	check("B3: albedo world RID == principal world RID (variant B: live shared world = no ghost)", sub_world == root_world)

	_finish()


func _finish() -> void:
	print("")
	print("RESULT: ", ("FAILED (%d)" % _failures) if _failures > 0 else "ALL CHECKS PASSED")
	quit(1 if _failures > 0 else 0)
