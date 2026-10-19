@tool
class_name SSRTAlbedoSource
extends SubViewport
## Renders an UNSHADED (unlit albedo) view of the LIVE scene into this viewport's
## render target, mirroring a source camera every frame.
##
## Used by SSRT_CE as the "unlit albedo" source: the GI bounce term is then multiplied
## by the scene's unlit albedo (see the "Accepted consequence" below) instead of the
## already-lit scene color (prevents overbrightening of directly-lit surfaces).
##
## LIVE-world rendering (variant B): this viewport does NOT use its own world and does
## NOT duplicate the scene. It renders the parent (main) world directly, so the
## geometry is always live — moving / adding / removing nodes in the scene is reflected
## in the albedo map with no per-frame sync (the old design kept a static duplicate
## that did not track runtime movement — the "ghost" bug). Camera selection in Godot 4
## is per-Viewport (see Camera3D.is_current()), so this SubViewport still renders the
## live world from its OWN camera, which we mirror from the source / editor camera.
##
## Accepted consequence: because it renders the main world, that world's Environment
## applies to the albedo output — its tonemapper, color adjustments and glow.
## `debug_draw = UNSHADOWED` strips lights / probes / voxel-GI / lightmaps / decals but
## NOT the environment's tonemap / adjustments / glow, so the map is the main world's
## tone-mapped albedo, not a perfectly raw one. (The previous isolated-world design
## gave a raw albedo at the cost of the static-duplicate "ghost".)
##
## The albedo map is screen-space: SSRT_CE samples it per pixel of the MAIN
## viewport, so this viewport must be rendered from the exact same camera as
## the main viewport:
## - in-game the main viewport uses `camera_source`;
## - in the editor the 3D preview is rendered from the editor's own viewport
##   camera (a child of the 3D screen's Node3DEditorViewport), which is NOT
##   `camera_source` and NOT the current camera of the SubViewport that hosts
##   the scene: the editor parks the edited scene in its own non-rendering
##   scene-root SubViewport, whose registered camera is the scene's own
##   Camera3D — static in the editor (its script is not @tool, animations do
##   not play). Mirroring that camera freezes the albedo at the scene
##   camera's pose; the mirror must follow the 3D editor viewport camera.
##
## Known editor-mode limitations (degrade, never crash):
## - Cinema/camera preview: the 3D preview raster is then attached to the
##   scene camera at render-server level (viewport_attach_camera) while
##   get_camera_3d() still returns the editor camera, so the albedo map is
##   misaligned until the preview is exited.
## - Multi-viewport layouts (2/3/4 3D views): the CE runs in every view and
##   render_size is last-writer-wins, so the single albedo map (mirrored from
##   the main view's camera) may not match the other views' rasters exactly.
##
## @tool is required: without it the editor never runs _ready/_process, so the
## handoff (viewport_rid/size) stays empty and SSRT_CE silently falls back to the
## legacy lit-color modulation in the 3D preview.
##
## Output stays HDR on write because:
## - use_hdr_2d is on -> the render target is HDR (no sRGB conversion on write).
## (The main world's tonemap / adjustments / glow still apply on top — see the
## "Accepted consequence" above.)

## Camera whose transform is mirrored into this viewport every frame (in-game).
## In the editor the editor's own 3D viewport camera is mirrored instead,
## because the scene view preview is rendered from it (not from this camera).
@export var camera_source: Camera3D
## Handoff resource shared with SSRT_CE (see albedo_handoff.gd).
@export var albedo_handoff: Resource

var _camera_target: Camera3D
# Cached render SubViewport of the 3D editor screen (editor only): the
# edited scene is NOT hosted inside it, so it must be located by scanning
# the editor tree, not by walking this node's parents.
var _editor_3d_vp_cache: SubViewport = null
var _editor_rescan_frames := 0

func _ready() -> void:
	# Variant B: render the LIVE (parent/main) world directly instead of an
	# isolated world + a duplicate of the scene. own_world_3d = false makes
	# find_world_3d() walk up to the main world, so the albedo map always shows
	# the current scene geometry (no static "ghost" duplicate). The SubViewport
	# still renders from its OWN camera (camera selection is per-Viewport), which
	# we mirror from the source / editor camera every frame below.
	own_world_3d = false

	# Render every frame; child viewports render before their parent, so the
	# target is fresh when the parent's compositor effect samples it.
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# UNSHADOWED strips lights / probes / voxel-GI / lightmaps / decals so the map
	# is unlit. (The main world's environment tonemap / adjustments / glow still
	# apply on top — see the header "Accepted consequence".)
	debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	use_hdr_2d = true

	# Render at the main viewport size (the mix pass scales UVs if they differ).
	if size.x == 0 or size.y == 0:
		size = _target_size()

	# A camera is required to render the live world from; it is mirrored every
	# frame from camera_source (in-game) or the editor viewport camera (editor).
	_camera_target = _find_or_create_camera()
	_update_handoff()


func _process(_delta: float) -> void:
	var target_size := _target_size()
	if size != target_size:
		size = target_size
		_update_handoff()

	if not _camera_target:
		return
	var src: Camera3D = null
	if Engine.is_editor_hint():
		# In the editor the 3D preview is rendered from the editor's own
		# viewport camera, which the editor updates every frame. The albedo map
		# is screen-space, so it must be rendered from that same camera.
		src = _editor_3d_camera()
	elif camera_source:
		# Mirror the source camera. In tree order this runs after the source
		# camera's own _process and its AnimationPlayer, so it picks up the
		# final transform.
		src = camera_source
	if src:
		# The editor branch may not have a camera yet (3D screen not open) and
		# camera_source may be unset: in either case keep the previous mirror.
		_apply_mirror_camera(src)


func _apply_mirror_camera(cam: Camera3D) -> void:
	# Copy the FULL camera state (pose + projection), not just the transform.
	# The mirror is a separate Camera3D node with its own default values;
	# copying only global_transform (the old in-game branch) leaves its own
	# fov / projection / near / far in place, so the albedo map and the main
	# raster disagree on scale and look misaligned (the in-game "FOV mismatch"
	# bug). Both the editor and the in-game paths now share this copy.
	_camera_target.global_transform = cam.global_transform
	_camera_target.fov = cam.fov
	_camera_target.projection = cam.projection
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera_target.size = cam.size
	_camera_target.near = cam.near
	_camera_target.far = cam.far


func _editor_3d_camera() -> Camera3D:
	var vp := _editor_3d_viewport()
	return vp.get_camera_3d() if vp else null


func _editor_3d_viewport() -> SubViewport:
	if _editor_3d_vp_cache and is_instance_valid(_editor_3d_vp_cache) and _editor_3d_vp_cache.is_inside_tree():
		return _editor_3d_vp_cache
	# The 3D editor screen is created lazily, so (re)scan the editor tree
	# until it appears; rescans are throttled to one per
	# `_editor_rescan_frames` calls (a few times per second while empty).
	if _editor_rescan_frames > 0:
		_editor_rescan_frames -= 1
		return null
	_editor_rescan_frames = 30
	_editor_3d_vp_cache = _find_editor_3d_viewport(_editor_top_root())
	return _editor_3d_vp_cache


func _editor_top_root() -> Node:
	# In the editor the scene being edited lives inside the editor's
	# scene_root SubViewport — a nested Viewport with its OWN SceneTree, so
	# get_tree().root is that SubViewport, NOT the editor's main Window.
	# Parent links do cross viewport boundaries, so walk them to reach the
	# topmost root (the editor window) and scan from there.
	# NOTE: `var n: Node = self` — a typed `Node`, NOT `var n := self`:
	# `:=` would infer this script's own type and the first parent
	# (a Node3D) would fail the assignment at runtime.
	var n: Node = self
	while n.get_parent():
		n = n.get_parent()
	return n


func _find_editor_3d_viewport(from: Node) -> SubViewport:
	# First visible Node3DEditorViewport in tree order is the main
	# (perspective) 3D editor view (the editor always shows it and hides the
	# other three by their local `visible` flag); return its render
	# SubViewport. If the whole 3D screen is hidden the main view's local
	# flag still reads true — mirroring then is harmless (the effect does
	# not render off-screen).
	for child in from.get_children():
		# get_class() returns the runtime class name directly — the most
		# direct match for an internal editor class (no is_class/GDType
		# hierarchy indirection).
		if child is Control and child.get_class() == "Node3DEditorViewport" and child.visible:
			return _first_subviewport(child)
		var found := _find_editor_3d_viewport(child)
		if found:
			return found
	return null


func _first_subviewport(from: Node) -> SubViewport:
	for child in from.get_children():
		if child is SubViewport:
			return child
		var found := _first_subviewport(child)
		if found:
			return found
	return null


func _target_size() -> Vector2i:
	# The CE's raster size is the authoritative target: the mix pass samples
	# the albedo map per-pixel of that raster, so this viewport must match it.
	# The CE publishes it to the handoff every frame (render thread, 1-frame
	# lag). In the editor this is the only reliable source — neither the
	# scene-root container's `size` nor (before round 5) anything else
	# reflected the 3D panel's render size, which is why the albedo map used
	# to stay 2x2 there.
	if albedo_handoff:
		var ce_size: Vector2i = albedo_handoff.render_size
		if ce_size.x > 0 and ce_size.y > 0:
			return ce_size
	# Fallbacks: before the CE has published a size (first frames) or when the
	# effect is disabled / handoff detached (legacy mode).
	if not Engine.is_editor_hint():
		# In-game the main viewport IS the root window, so its size is the
		# right mirror target (and keeps the albedo map aspect-aligned with
		# the effect's raster).
		return get_tree().root.size
	# In the editor the root window is the whole editor; the 3D preview
	# renders from the 3D editor viewport, so mirror its size to keep the
	# aspect matched with the preview.
	var host := _editor_3d_viewport()
	if host:
		var vp_size := host.get_size()
		if vp_size.x > 0 and vp_size.y > 0:
			return vp_size
	return get_tree().root.size


func _find_or_create_camera() -> Camera3D:
	var cameras := find_children("", "Camera3D")
	if not cameras.is_empty():
		return cameras[0]
	var camera := Camera3D.new()
	add_child(camera)
	return camera


func _update_handoff() -> void:
	if not albedo_handoff:
		return
	albedo_handoff.viewport_rid = get_viewport_rid()
	albedo_handoff.albedo_size = size
