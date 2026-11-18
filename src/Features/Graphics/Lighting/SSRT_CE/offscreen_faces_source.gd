@tool
class_name SSRTOffscreenFaces
extends Node

## Builds and drives the five offscreen side-capture viewports for SSRT_CE: shared
## main world (own_world_3d = false, same trick as SSRTAlbedoSource), each a square
## 90-degree-frustum camera at the source camera's position pointed right / left /
## up / down / back, rendering the FULLY LIT scene. A per-viewport
## SSRTOffscreenFaceCapture effect copies color + linear depth into the face arrays;
## SSRT_CE reallocs them from the settings, this node only sizes and triggers renders.
##
## Wire it to the same SSRTSettings + SSRTOffscreenHandoff as SSRT_CE (README install
## step). With offscreen_capture_enabled = false the side viewports never render.

const FACE_COUNT := 5
const FACE_NAMES := ["Right", "Left", "Up", "Down", "Back"]

##Local rotation putting the camera's -Z on the side axis, index order matching
##FACE_FORWARD/FACE_UP in trace.glsl and face_mask() bits in SSRT_settings.gd.
const FACE_LOCAL_BASIS := [
	Basis(Vector3.UP, -PI / 2.0),     #right: fwd -> +X
	Basis(Vector3.UP, PI / 2.0),      #left: fwd -> -X
	Basis(Vector3.RIGHT, PI / 2.0),   #up: fwd -> +Y
	Basis(Vector3.RIGHT, -PI / 2.0),  #down: fwd -> -Y
	Basis(Vector3.UP, PI),            #back: fwd -> -Z (camera back)
]

## Same SSRTSettings resource the SSRT_CE effect uses; drives enable/sides/size/frequency.
@export var settings: SSRTSettings:
	set(value):
		if settings == value:
			return
		settings = value
		_reconnect_settings()

## SSRTOffscreenHandoff resource shared with SSRT_CE.
@export var face_handoff: Resource

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
	var px := settings.face_size_px()
	var period := 1.0 / float(settings.face_update_frequency)

	var src := _source_camera()
	for i in FACE_COUNT:
		var vp := _viewports[i]
		if not settings.offscreen_capture_enabled or (mask & (1 << i)) == 0:
			if vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
				vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			continue

		#Re-assert wiring so swapping handoff/settings in the inspector takes effect
		#without a restart (allocation/realloc itself is SSRT_CE's render-thread job).
		_effects[i].handoff = face_handoff as SSRTOffscreenHandoff
		if vp.size.x != px:
			vp.size = Vector2i(px, px)
		if src:
			#Same origin, fixed 90-degree frustum; near/far match the source so the
			#stored linear depth is directly comparable against the trace's probe.
			_cameras[i].global_transform = src.global_transform * Transform3D(FACE_LOCAL_BASIS[i], Vector3.ZERO)
			_cameras[i].near = src.near
			_cameras[i].far = src.far

		_accum[i] += delta
		if _accum[i] >= period:
			_accum[i] = 0.0
			#UPDATE_ONCE raises the viewport's render flag on every assignment
			#(verified on 4.7.2); DISABLED<->ALWAYS toggling does NOT re-render.
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _build_faces() -> void:
	var px := settings.face_size_px() if settings else 256
	_accum.resize(FACE_COUNT)
	for i in FACE_COUNT:
		var vp := SubViewport.new()
		vp.name = "OffscreenFace_%s" % FACE_NAMES[i]
		#Share the main world; no node duplication. The per-camera compositor below
		#shadows the world compositor, so SSRT_CE itself never runs on this viewport.
		vp.own_world_3d = false
		vp.size = Vector2i(px, px)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		#4.7 has no scaling OFF: NEAREST at scale 1.0 keeps the raster 1:1.
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_NEAREST
		vp.scaling_3d_scale = 1.0
		vp.transparent_bg = false
		add_child(vp)

		var cam := Camera3D.new()
		cam.name = "FaceCamera_%s" % FACE_NAMES[i]
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = 90.0
		var eff := SSRTOffscreenFaceCapture.new()
		eff.face_index = i
		eff.handoff = face_handoff as SSRTOffscreenHandoff
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
