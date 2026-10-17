class_name SSRTAlbedoSource
extends SubViewport
## Renders an UNSHADED (unlit albedo) duplicate of a scene subtree into this viewport's
## render target, mirroring a source camera every frame.
##
## Used by SSRT_CE as the "unlit albedo" source: the GI bounce term is then multiplied
## by the true material albedo instead of the already-lit scene color (prevents
## overbrightening of directly-lit surfaces).
##
## Output stays linear because:
## - use_hdr_2d is on -> the render target is HDR (no sRGB conversion on write)
## - a linear-tonemap environment with adjustments disabled is added below

## Scene subtree to render as unlit albedo (e.g. the main scene's geometry root).
@export var albedo_geometry: Node3D
## Camera whose transform is mirrored into this viewport every frame.
@export var camera_source: Camera3D
## Handoff resource shared with SSRT_CE (see albedo_handoff.gd).
@export var albedo_handoff: Resource

var _instance: Node3D
var _camera_target: Camera3D


func _ready() -> void:
	# Render every frame; child viewports render before their parent, so the
	# target is fresh when the parent's compositor effect samples it.
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	use_hdr_2d = true

	# Render at window size (the mix pass scales UVs if the sizes differ).
	if size.x == 0 or size.y == 0:
		size = get_tree().root.size

	# Minimal linear environment: nothing should alter the raw albedo output.
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	_camera_target = _find_or_create_camera()
	_rebuild_instance()
	_update_handoff()


func _process(_delta: float) -> void:
	var root_size := get_tree().root.size
	if size != root_size:
		size = root_size
		_update_handoff()

	# Mirror the source camera. In tree order this runs after the source camera's
	# own _process and its AnimationPlayer, so it picks up the final transform.
	if camera_source and _camera_target:
		_camera_target.global_transform = camera_source.global_transform


func _find_or_create_camera() -> Camera3D:
	var cameras := find_children("", "Camera3D")
	if not cameras.is_empty():
		return cameras[0]
	var camera := Camera3D.new()
	add_child(camera)
	return camera


func _rebuild_instance() -> void:
	if _instance:
		if _instance.is_inside_tree():
			_instance.queue_free()
		else:
			_instance.free()
		_instance = null

	if not albedo_geometry:
		return

	# duplicate() shares meshes and materials by reference, so the albedo
	# matches the source scene exactly.
	_instance = albedo_geometry.duplicate(true)
	add_child(_instance)


func _update_handoff() -> void:
	if not albedo_handoff:
		return
	albedo_handoff.viewport_rid = get_viewport_rid()
	albedo_handoff.albedo_size = size
