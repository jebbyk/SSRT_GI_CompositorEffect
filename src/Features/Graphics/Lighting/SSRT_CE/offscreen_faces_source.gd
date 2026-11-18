@tool
class_name SSRTOffscreenFaces
extends Node

## Builds and drives the five offscreen side-capture viewports for SSRT_CE: shared
## main world (own_world_3d = false, same trick as SSRTAlbedoSource), each a camera at
## the source camera's position using the SAME projection as the source (fov/near/far
## copied, viewport aspect matched via handoff.face_size) so every side shares the
## main camera's frustum shape.
##
## Face yaw/pitch are pulled IN from the main screen edge by OVERLAP_DEG so the side
## frustums overlap the main view and leave no dead band where freshly-exited rays
## live (a plain 90-degree cube starts covering only at 45 degrees, while a typical
## main frustum exits at ~25-30). The angles go to SSRT_CE via the handoff; the trace
## shader builds the matching frustum axes from them.
##
## Wire it to the same SSRTSettings + SSRTOffscreenHandoff as SSRT_CE (README install
## step). With offscreen_capture_enabled = false the side viewports never render.

const FACE_COUNT := 5
const FACE_NAMES := ["Right", "Left", "Up", "Down", "Back"]
## How far each side frustum is pulled toward the main view (degrees of overlap).
const OVERLAP_DEG := 10.0
## Yaw/pitch clamp so tiny/huge FOVs can't collapse the coverage.
const ANGLE_MIN_DEG := 40.0
const ANGLE_MAX_DEG := 135.0

## Same SSRTSettings resource the SSRT_CE effect uses; drives enable/sides/size/frequency.
@export var settings: SSRTSettings:
	set(value):
		if settings == value:
			return
		settings = value
		_reconnect_settings()

## SSRTOffscreenHandoff resource shared with SSRT_CE.
@export var face_handoff: SSRTOffscreenHandoff

## Optional override, same semantics as SSRTAlbedoSource.camera_source: unset follows
## the window's active camera (editor preview mirrors the editor viewport camera).
@export var camera_source: Camera3D

var _viewports: Array[SubViewport] = []
var _cameras: Array[Camera3D] = []
var _effects: Array[SSRTOffscreenFaceCapture] = []
var _accum: PackedFloat32Array = PackedFloat32Array()

var _editor_3d_vp_cache: SubViewport = null
var _editor_rescan_frames := 0


func _ready() -> void:
	_reconnect_settings()
	if _viewports.is_empty():
		_build_faces()


func _process(delta: float) -> void:
	if not settings or _viewports.is_empty():
		return

	var mask := settings.face_mask()
	var period := 1.0 / float(settings.face_update_frequency)
	var target_size := face_handoff.face_size if face_handoff else Vector2i.ZERO

	var src := _source_camera()
	var bases : Array = []
	if src:
		#Side frustum angles from the SOURCE projection: yaw covers the horizontal
		#faces, pitch the vertical ones; back stays fixed at 180 degrees.
		var aspect := 1.0
		if face_handoff and face_handoff.main_aspect > 0.0:
			aspect = face_handoff.main_aspect
		var hfov := rad_to_deg(2.0 * atan(tan(deg_to_rad(src.fov) * 0.5) * aspect))
		var yaw := clampf(hfov - OVERLAP_DEG, ANGLE_MIN_DEG, ANGLE_MAX_DEG)
		var pitch := clampf(src.fov - OVERLAP_DEG, ANGLE_MIN_DEG, ANGLE_MAX_DEG)
		face_handoff.face_yaw = deg_to_rad(yaw)
		face_handoff.face_pitch = deg_to_rad(pitch)

		bases = [
			Basis(Vector3.UP, -deg_to_rad(yaw)),         #right
			Basis(Vector3.UP, deg_to_rad(yaw)),          #left
			Basis(Vector3.RIGHT, deg_to_rad(pitch)),     #up
			Basis(Vector3.RIGHT, -deg_to_rad(pitch)),    #down
			Basis(Vector3.UP, PI),                       #back
		]

	for i in FACE_COUNT:
		var vp := _viewports[i]
		if not settings.offscreen_capture_enabled or (mask & (1 << i)) == 0:
			if vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
				vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			continue

		#Re-assert wiring so swapping handoff/settings in the inspector takes effect
		#without a restart (array allocation itself is SSRT_CE's render-thread job).
		_effects[i].handoff = face_handoff
		if target_size != Vector2i.ZERO and vp.size != target_size:
			vp.size = target_size
		if src:
			_cameras[i].global_transform = src.global_transform * Transform3D(bases[i], Vector3.ZERO)
			_cameras[i].fov = src.fov
			_cameras[i].near = src.near
			_cameras[i].far = src.far

		_accum[i] += delta
		if _accum[i] >= period:
			_accum[i] = 0.0
			#UPDATE_ONCE raises the viewport's render flag on every assignment
			#(verified on 4.7.2); DISABLED<->ALWAYS toggling does NOT re-render.
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _build_faces() -> void:
	_accum.resize(FACE_COUNT)
	for i in FACE_COUNT:
		var vp := SubViewport.new()
		vp.name = "OffscreenFace_%s" % FACE_NAMES[i]
		#Share the main world; no node duplication. The per-camera compositor below
		#shadows the world compositor, so SSRT_CE itself never runs on this viewport.
		vp.own_world_3d = false
		vp.size = Vector2i(256, 256)  #resized to handoff.face_size once the CE publishes it
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		#4.7 has no scaling OFF: NEAREST at scale 1.0 keeps the raster 1:1.
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_NEAREST
		vp.scaling_3d_scale = 1.0
		vp.transparent_bg = false
		add_child(vp)

		var cam := Camera3D.new()
		cam.name = "FaceCamera_%s" % FACE_NAMES[i]
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = 75.0  #overwritten from the source camera every frame
		var eff := SSRTOffscreenFaceCapture.new()
		eff.face_index = i
		eff.handoff = face_handoff
		var comp := Compositor.new()
		comp.compositor_effects = [eff]
		cam.compositor = comp
		vp.add_child(cam)

		_viewports.append(vp)
		_cameras.append(cam)
		_effects.append(eff)


func _reconnect_settings() -> void:
	if settings and not settings.s_changed.is_connected(_settings_changed):
		settings.s_changed.connect(_settings_changed)


func _settings_changed() -> void:
	#Size/enable/frequency are re-read every frame in _process; nothing persistent
	#to rebuild here (face texture allocation is SSRT_CE's render-thread job).
	pass


## Active source camera resolution, same precedence as SSRTAlbedoSource.
func _source_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var vp := _editor_3d_viewport()
		return vp.get_camera_3d() if vp else null
	if camera_source:
		return camera_source
	return get_tree().root.get_camera_3d() if is_inside_tree() else null


# Editor 3D-viewport lookup: duplicated from albedo_source_viewport.gd (engine-side
# search, no shared state to keep in sync).
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
