@tool
class_name SSRTOffscreenFaceCapture
extends BaseCompositorEffect

## Runs inside one offscreen side SubViewport (its camera's own compositor) at POST_SKY
## and copies that viewport's scene color + linear depth + native gbuffer normal into
## the face texture arrays owned by SSRT_CE. One instance per face; SSRTOffscreenFaces
## creates and wires them.

const FACE_COLOR_BINDING := 0
const FACE_NORMAL_BINDING := 1

## Assigned by SSRTOffscreenFaces at build time (re-asserted every frame there).
var handoff: SSRTOffscreenHandoff
## Face layer index: 0 right, 1 left, 2 up, 3 down, 4 back (order fixed across SSRT_CE).
var face_index: int = 0

var capture_shader : RID
var capture_pipeline : RID


##Shaders live next to this script, so the whole folder can be dropped anywhere.
func _shader(p_name: String) -> String:
	return get_script().resource_path.get_base_dir().path_join("shaders/").path_join(p_name)


func _initialize_resource() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_SKY
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true


func _initialize_render() -> void:
	capture_shader = create_shader(_shader("face_capture.glsl"))
	capture_pipeline = create_pipeline(capture_shader)


func _render_view(p_view : int) -> void:
	if not handoff or handoff.face_size == Vector2i.ZERO:
		return
	if not capture_pipeline.is_valid() or not capture_shader.is_valid():
		return
	if not handoff.face_color_array.is_valid() or not handoff.face_normal_array.is_valid():
		return

	var sets : Array[Array] = [
		[
			get_scene_data_ubo(),
			get_color_image_uniform(p_view),
			get_depth_sampler_uniform(p_view, nearest_sampler),
			get_normal_image_uniform(),
		],
		[
			get_image_uniform(handoff.face_color_array, FACE_COLOR_BINDING),
			get_image_uniform(handoff.face_normal_array, FACE_NORMAL_BINDING),
		],
	]

	#16 bytes: raster size + face layer index (push constants; spec constants are
	#silently ignored by this engine).
	var push := PackedFloat32Array([float(render_size.x), float(render_size.y), float(face_index), 0.0])

	run_compute_shader(
		"SSRT: Face Capture %d" % face_index,
		capture_shader,
		capture_pipeline,
		sets,
		push,
	)
	handoff.render_counts[face_index] += 1
