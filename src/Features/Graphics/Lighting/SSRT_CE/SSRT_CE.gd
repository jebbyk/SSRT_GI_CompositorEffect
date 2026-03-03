@tool
class_name SSRT_CE
extends BaseCompositorEffect

#TODO use includes
#TODO simple denoise (blur)
#TODO advanced denoise (ray cone spot i.e. far samples are wider)
#TODO GI (bounce and AO) boost on steep angles (togleable)
#TODO more advanced denoise with samples accumulation from several frames
#TODO even more advanced denosie with motion vectors taken into account
#TODO optimize with BVH (ye it is possible to build one on a GPU)
#TODO read GI probes from lit albedo, multiply GI to unlit albedo and only then mix it (now it is only possible with help of viewport rendering to a texture)
#TODO rays miss to sky color and ground color
#TODO ray miss to scene skybox
#TODO retrieve metalicity buffer and use it to proper reflections
#TODO do effect before transparents
#TODO make it compatible with upscaling (screen quad version remains sharp even with fsr2.1 x0.5)
#TODO use multiple cameras setup to capture offscreen things
#TODO use scene voxelization and voxel tracing (maybe as separate CE) (the key difference from original is an actual tracing)

const TRACE_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/trace.glsl"

const USE_DEBUG_IMAGE = false

#Set 1 bindings
const SETTINGS_UBO_BINDING := 0
const DEBUG_IMAGE_BINDING := 1

#TODO Set 2 bindings ?
#TODO Specialization constant bindings?

@export  var settings : SSRTSettings :
	set(value):
		settings = value
		setup_settings()
		
#TODO Debug things?

var context : StringName = "SSRT_CE"

#TODO texture a \ b

var depth_texture : StringName = "DepthTexture"
var depth_image_uniform : RDUniform

var settings_ubo : RID
var settings_ubo_uniform : RDUniform

var trace_shader : RID
var trace_pipeline : RID

var push_constant: PackedFloat32Array;

var settings_dirty: bool = false


func _initialize_resource() -> void:
	print("from SSRT_CE::_initialize_resource()")
	if not settings:
		settings = SSRTSettings.new()
		setup_settings()
	
	access_resolved_depth = true
	access_resolved_color = true
	needs_normal_roughness = true
		
		
func _initialize_render() -> void: 
	print("from SSRT_CE::_initialize_render()")
	trace_shader = create_shader(TRACE_SHADER_PATH)
	if not trace_shader.is_valid():
		push_error("from SSRT_CE::_initialize_render(). Failed to create trace shader")
	
	
func _render_setup() -> void:
	if not settings_ubo.is_valid() or settings_dirty:
		print("from SSRT_CE::_render_setup(). Settings are dirty")
		create_settings_uniform_buffer()
		create_trace_pipeline()

	push_constant = _build_push_constant(render_size)
		

func create_trace_pipeline() -> void:
	if not trace_shader.is_valid():
		push_error("from SSRT_CE::create_trace_pipeline() Trace shader is not valid")
		
	if rd.compute_pipeline_is_valid(trace_pipeline):
		rd.free_rid(trace_pipeline)
		
	trace_pipeline = create_pipeline(trace_shader)
	
	
func _render_view(p_view : int) -> void:
	var scene_uniform_set : Array[RDUniform] = get_scene_uniform_set(p_view)
	var settings_uniform_set : Array[RDUniform] = [settings_ubo_uniform]
	
	var uniform_sets : Array[Array]
	
	#trace pass
	uniform_sets = [
		scene_uniform_set,
		settings_uniform_set,
	]
	
	run_compute_shader(
		"SSRT: Trace",
		trace_shader,
		trace_pipeline,
		uniform_sets,
		push_constant,
	)


func _render_size_changed() -> void:
	print("from SSRT_CE::_render_size_changed()")
	render_scene_buffers.clear_context(context)
	make_settings_dirty()
	
	
func _settings_changed() -> void:
	print("from SSRT_CE::_settings_changed()")
	render_scene_buffers.clear_context(context)
	make_settings_dirty()


func create_settings_uniform_buffer() -> void:
	if settings_ubo.is_valid():
		free_rid(settings_ubo)
		
	var data: Array = [
		#vec3
		settings.sky_color,

		#float
		settings.rays_amount,
		settings.steps_per_ray,
		settings.bounce_intensity,
		settings.occlusion_intensity,
		settings.ray_length,
		settings.z_thickness,
		settings.sky_color_intensity,
		settings.far_plane,

		#bool
		settings.depth_affect_ray_length,
		settings.back_face_lighting
	]
	
	settings_ubo = create_uniform_buffer(data)
	settings_ubo_uniform = get_uniform_buffer_uniform(settings_ubo, SETTINGS_UBO_BINDING)
	settings_dirty = false
		

func _build_push_constant(p_render_size: Vector2i) -> PackedFloat32Array:
	push_constant= PackedFloat32Array()
	push_constant.push_back(p_render_size.x)
	push_constant.push_back(p_render_size.y)
	push_constant.push_back(0.0)
	push_constant.push_back(0.0)
	return push_constant


func setup_settings() -> void:
	print("from SSRT_CE::setup_settings()")
	if not settings.s_changed.is_connected(_settings_changed):
		settings.s_changed.connect(_settings_changed)
		
		

		
func make_settings_dirty() -> void:
	print("from SSRT_CE::make_settings_dirty()")
	settings_dirty = true
