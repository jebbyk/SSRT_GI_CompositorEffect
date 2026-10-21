@tool
class_name SSRTAlbedoSource
extends SubViewport
## Renders an UNSHADED (unlit albedo) view of the LIVE scene into this viewport's
## render target, mirroring a source camera every frame.
##
## Used by SSRT_CE as the "unlit albedo" source: the GI bounce term is then multiplied
##
## The albedo map is screen-space: SSRT_CE samples it per pixel of the MAIN
## viewport, so this viewport must be rendered from the exact same camera as
## the main viewport:
## - in-game the main viewport uses `camera_source`;
## - in the editor the 3D preview is rendered from the editor's own viewport
##   camera
##
## Known editor-mode limitations (degrade, never crash):
## - albedo map is misaligned until the preview is exited.
## - Multi-viewport layouts (2/3/4 3D views): the CE runs in every view and
##   render_size is last-writer-wins, so the single albedo map (mirrored from
##   the main view's camera) may not match the other views' rasters exactly.

# Camera whose transform is mirrored into this viewport every frame (in-game).
@export var camera_source: Camera3D
# Handoff resource shared with SSRT_CE (see albedo_handoff.gd).
@export var albedo_handoff: Resource

var _camera_target: Camera3D
var _editor_3d_vp_cache: SubViewport = null
var _editor_rescan_frames := 0

func _ready() -> void:
	own_world_3d = false

	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# UNSHADOWED strips lights / probes / voxel-GI / lightmaps / decals so the map
	# is unlit.
	debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	use_hdr_2d = true

	if size.x == 0 or size.y == 0:
		size = _target_size()

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
		src = _editor_3d_camera()
	elif camera_source:
		src = camera_source
	if src:
		_apply_mirror_camera(src)


func _apply_mirror_camera(cam: Camera3D) -> void:
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
	if _editor_rescan_frames > 0:
		_editor_rescan_frames -= 1
		return null
	_editor_rescan_frames = 30
	_editor_3d_vp_cache = _find_editor_3d_viewport(_editor_top_root())
	return _editor_3d_vp_cache


func _editor_top_root() -> Node:
	var n: Node = self
	while n.get_parent():
		n = n.get_parent()
	return n


func _find_editor_3d_viewport(from: Node) -> SubViewport:
	for child in from.get_children():
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
	if albedo_handoff:
		var ce_size: Vector2i = albedo_handoff.render_size
		if ce_size.x > 0 and ce_size.y > 0:
			return ce_size
	if not Engine.is_editor_hint():
		return get_tree().root.size
		
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
