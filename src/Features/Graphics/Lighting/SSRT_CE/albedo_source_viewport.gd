@tool
class_name SSRTAlbedoSource
extends SubViewport
## Renders an UNSHADED (unlit albedo) duplicate of a scene subtree into this viewport's
## render target, mirroring a source camera every frame.
##
## Used by SSRT_CE as the "unlit albedo" source: the GI bounce term is then multiplied
## by the true material albedo instead of the already-lit scene color (prevents
## overbrightening of directly-lit surfaces).
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
## Output stays linear because:
## - use_hdr_2d is on -> the render target is HDR (no sRGB conversion on write)
## - a linear-tonemap environment with adjustments disabled is added below

## Scene subtree to render as unlit albedo (e.g. the main scene's geometry root).
@export var albedo_geometry: Node3D
## Camera whose transform is mirrored into this viewport every frame (in-game).
## In the editor the editor's own 3D viewport camera is mirrored instead,
## because the scene view preview is rendered from it (not from this camera).
@export var camera_source: Camera3D
## Handoff resource shared with SSRT_CE (see albedo_handoff.gd).
@export var albedo_handoff: Resource

var _instance: Node3D
var _camera_target: Camera3D
# Cached render SubViewport of the 3D editor screen (editor only): the
# edited scene is NOT hosted inside it, so it must be located by scanning
# the editor tree, not by walking this node's parents.
var _editor_3d_vp_cache: SubViewport = null
var _editor_rescan_frames := 0

#TEMP [ALBEDO-CAM-DIAG] round-5 editor camera-follow diagnosis (remove after diagnosis).
var _cam_diag_ticks := 0
var _cam_diag_captured := 0
var _cam_diag_probe_done := false

#Group membership keeps _ready idempotent across editor script reloads (a
#re-run of _ready must not accumulate duplicates/environments) while leaving
#node names untouched — the duplicate keeps the source node's name.
const ALBEDO_INSTANCE_GROUP := &"ssrt_albedo_instance"
const ALBEDO_ENVIRONMENT_GROUP := &"ssrt_albedo_environment"


func _ready() -> void:
	# Render every frame; child viewports render before their parent, so the
	# target is fresh when the parent's compositor effect samples it.
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	use_hdr_2d = true

	# Render at the main viewport size (the mix pass scales UVs if they differ).
	if size.x == 0 or size.y == 0:
		size = _target_size()

	# Minimal linear environment: nothing should alter the raw albedo output.
	#Remove any leftover from a previous script instance (editor reload) first.
	_remove_group_children(ALBEDO_ENVIRONMENT_GROUP)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world_environment.add_to_group(ALBEDO_ENVIRONMENT_GROUP)
	add_child(world_environment)

	_camera_target = _find_or_create_camera()
	_rebuild_instance()
	_update_handoff()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		#TEMP [ALBEDO-CAM-DIAG] round-5 editor camera-follow diagnosis (remove after diagnosis).
		_cam_diag_step()
	var target_size := _target_size()
	if size != target_size:
		size = target_size
		_update_handoff()

	if not _camera_target:
		return
	if Engine.is_editor_hint():
		_mirror_editor_camera()
	elif camera_source:
		# Mirror the source camera. In tree order this runs after the source
		# camera's own _process and its AnimationPlayer, so it picks up the
		# final transform.
		_camera_target.global_transform = camera_source.global_transform


func _host_viewport() -> SubViewport:
	# The first SubViewport ancestor. In the editor that is the editor's
	# non-rendering scene-root SubViewport (the container that parks the
	# edited scene) — NOT the 3D editor viewport; in-game there is none.
	var vp := get_parent()
	while vp:
		if vp is SubViewport:
			return vp
		vp = vp.get_parent()
	return null


func _mirror_editor_camera() -> void:
	# In the editor the 3D preview is rendered from the editor's own viewport
	# camera, which the editor updates every frame. The albedo map is
	# screen-space, so it must be rendered from that same camera.
	var cam := _editor_3d_camera()
	if not cam:
		# 3D editor screen not open/created yet, or viewport not ready:
		# keep the previous transform.
		return
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


#TEMP [ALBEDO-CAM-DIAG] one-shot probe helper (remove after diagnosis).
func _count_editor_views(from: Node) -> Array:
	var total := 0
	var visible := 0
	for child in from.get_children():
		if child is Control and child.get_class() == "Node3DEditorViewport":
			total += 1
			if child.visible:
				visible += 1
		var sub := _count_editor_views(child)
		total += sub[0]
		visible += sub[1]
	return [total, visible]


#TEMP [ALBEDO-CAM-DIAG] round-5 editor camera-follow diagnosis (remove after diagnosis).
#One compact line per second: host camera (identity + pose) vs mirror pose vs
#source camera, plus the sizes — so frozen / lagging / wrong-camera can be told
#apart from the log alone. Two albedo+host PNG pairs at ~10s and ~20s let the
#albedo view be compared against the editor view at two different camera poses.
func _cam_diag_step() -> void:
	_cam_diag_ticks += 1
	var host := _host_viewport()
	var hcam: Camera3D = host.get_camera_3d() if host else null
	var ecam := _editor_3d_camera()
	if ecam == null and not _cam_diag_probe_done:
		#TEMP [ALBEDO-CAM-DIAG] one-shot probe: separates "class never matched"
		#(0) from "found but hidden" (>0) if the search keeps returning null.
		_cam_diag_probe_done = true
		var top := _editor_top_root()
		var cnt := _count_editor_views(top)
		print("[ALBEDO-CAM-DIAG] PROBE top_root=%s editor_views=%d visible=%d" % [top.get_class(), cnt[0], cnt[1]])
	if _cam_diag_ticks % 30 == 0:
		print("[ALBEDO-CAM-DIAG] t=%d | ed3d_cam=%s | host_cam=%s | mirror=%s | src=%s | size=%s | ce_size=%s | mirror_is_sv_cam=%s" % [
			_cam_diag_ticks,
			("id=%d @ %s fov=%.1f" % [ecam.get_instance_id(), ecam.global_transform.origin, ecam.fov]) if ecam else "NULL",
			("id=%d @ %s fov=%.1f" % [hcam.get_instance_id(), hcam.global_transform.origin, hcam.fov]) if hcam else "NULL",
			("%s fov=%.1f" % [_camera_target.global_transform.origin, _camera_target.fov]) if _camera_target else "NULL",
			str(camera_source.global_transform.origin) if camera_source else "NULL",
			str(size),
			str(albedo_handoff.render_size) if albedo_handoff else "n/a",
			str(get_camera_3d() == _camera_target),
		])
	if _cam_diag_ticks == 600 or _cam_diag_ticks == 1200:
		_cam_diag_captured += 1
		print("[ALBEDO-CAM-DIAG] CAPTURE %d — orbit the editor camera between captures" % _cam_diag_captured)
		var atex := get_texture()
		if atex:
			var aimg: Image = atex.get_image()
			if aimg and not aimg.is_empty():
				aimg.save_png("/tmp/opencode/albedo_cam_diag_%d_albedo.png" % _cam_diag_captured)
		if host:
			var htex := host.get_texture()
			if htex:
				var himg: Image = htex.get_image()
				if himg and not himg.is_empty():
					himg.save_png("/tmp/opencode/albedo_cam_diag_%d_host.png" % _cam_diag_captured)


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


func _rebuild_instance() -> void:
	#Remove any previous duplicate (tracked or a leftover from an editor
	#script reload) before creating the new one.
	if _instance:
		_instance.free()
		_instance = null
	_remove_group_children(ALBEDO_INSTANCE_GROUP)

	if not albedo_geometry:
		return

	# duplicate() shares meshes and materials by reference, so the albedo
	# matches the source scene exactly.
	_instance = albedo_geometry.duplicate(true)
	_instance.add_to_group(ALBEDO_INSTANCE_GROUP)
	add_child(_instance)


func _remove_group_children(group_name: StringName) -> void:
	#get_children() returns a snapshot array, so freeing while iterating is safe.
	for child in get_children():
		if child.is_in_group(group_name):
			child.free()


func _update_handoff() -> void:
	if not albedo_handoff:
		return
	albedo_handoff.viewport_rid = get_viewport_rid()
	albedo_handoff.albedo_size = size
