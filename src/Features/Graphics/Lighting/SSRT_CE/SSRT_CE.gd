@tool
class_name SSRT_CE
extends BaseCompositorEffect

#TODO fix initialization process so there is no need to reload entire project on each shaders recompilation (problem is only on windows)
#TODO retrieving shader compilation errors (if not yet?)
#TODO reduce self-litting\occluding
#TODO use includes at full potential
#TODO controllable simple denoise (blur) passes count  
#TODO cancel blur pixel if depth is to far from original
#TODO remove fireflies (if needed)
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

const TRACE_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/trace.glsl"
const BLUR_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/blur.glsl"
const MIX_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/mix.glsl"

const USE_DEBUG_IMAGE = false

#Set 1 bindings
const SETTINGS_UBO_BINDING := 0
const DEBUG_IMAGE_BINDING := 1

#set 2 binding
const TEXTURE_IN_IMAGE_BINDING := 0
const TEXTURE_OUT_IMAGE_BINDING := 1

#TODO Specialization constant bindings?

@export_tool_button("Recompile shaders", "Callable") var recompile_shaders_action = _recompile_shaders

@export  var settings : SSRTSettings :
	set(value):
		settings = value
		setup_settings()
		
#TODO Debug things?

var context : StringName = "SSRT_CE"

var texture_a : StringName  = "TextureA"
var texture_a_in_image_uniform : RDUniform
var texture_a_out_image_uniform : RDUniform

var texture_b : StringName = "TextureB"
var texture_b_in_image_uniform : RDUniform
var texture_b_out_image_uniform : RDUniform

var depth_texture : StringName = "DepthTexture"
var depth_image_uniform : RDUniform

var settings_ubo : RID
var settings_ubo_uniform : RDUniform

var trace_shader : RID
var trace_pipeline : RID

var blur_shader : RID
var blur_pipeline : RID

var mix_shader : RID
var mix_pipeline : RID

var push_constant: PackedFloat32Array;

var settings_dirty: bool = false
var shaders_dirty: bool = false

#called once on resource creation (when effect is added to list, or when scene loaded)
func _initialize_resource() -> void:
	print("from: SSRT_CE::_initialize_resource()")
	if not settings:
		settings = SSRTSettings.new()
		setup_settings()
	
	access_resolved_depth = true
	access_resolved_color = true
	needs_normal_roughness = true
		
#called once on resource creation (when effect is added to list, or when scene loaded) after resource is initialized
func _initialize_render() -> void: 
	print("from: SSRT_CE::_initialize_render()")
	_recompile_shaders()
		
	
#called every frame before executing code for each view
func _render_setup() -> void:
	if not settings_ubo.is_valid() or settings_dirty or shaders_dirty:
		print("from: SSRT_CE::_render_setup(). msg: Settings are dirty")
		create_settings_uniform_buffer()
		create_trace_pipeline()
		create_blur_pipeline()
		create_mix_pipeline()
		shaders_dirty = false
	
	if not render_scene_buffers.has_texture(context, texture_a):
		create_textures()
		

	push_constant = _build_push_constant(render_size)#TODO no need to do it every frame?
		
#TODO use unified function for pipeline creation
func create_trace_pipeline() -> void:
	if not trace_shader.is_valid():
		push_error("from: SSRT_CE::create_trace_pipeline(). msg: Trace shader is not valid")
		
	if rd.compute_pipeline_is_valid(trace_pipeline):
		rd.free_rid(trace_pipeline)
		
	trace_pipeline = create_pipeline(trace_shader)
	
	
func create_blur_pipeline() -> void:
	if not blur_shader.is_valid():
		push_error("from: SSRT_CE::create_blur_pipeline(). msg: Blur shader is not valid")
		
	if rd.compute_pipeline_is_valid(blur_pipeline):
		rd.free_rid(blur_pipeline)
		
	blur_pipeline = create_pipeline(blur_shader)
	

func create_mix_pipeline() -> void:
	if not mix_shader.is_valid():
		push_error("from: SSRT_CE:create_mix_pipeline(). msg: Mix shader is not valid")
		
	if rd.compute_pipeline_is_valid(mix_pipeline):
		rd.free_rid(mix_pipeline)
	
	mix_pipeline = create_pipeline(mix_shader)
	
	
func _render_view(p_view : int) -> void:
	var scene_uniform_set : Array[RDUniform] = get_scene_uniform_set(p_view)
	var settings_uniform_set : Array[RDUniform] = [settings_ubo_uniform]
	
	var uniform_sets : Array[Array]
	
	#trace pass
	uniform_sets = [
		scene_uniform_set,
		settings_uniform_set,
		[texture_a_out_image_uniform],
	]
	
	run_compute_shader(
		"SSRT: Trace",
		trace_shader,
		trace_pipeline,
		uniform_sets,
		push_constant,
	)
	

	#blur passes
	var blur_distance: int = settings.blur_kernel_size
	
	for i in settings.blur_steps:
		
		uniform_sets = [
			scene_uniform_set,
			settings_uniform_set,
			[texture_a_in_image_uniform, texture_b_out_image_uniform]
		]
		
		run_compute_shader(
			"SSRT: blur",
			blur_shader,
			blur_pipeline,
			uniform_sets,
			push_constant,
		)
		
		blur_distance *= 3
		
	
	#overlay pass
	uniform_sets = [
		scene_uniform_set,
		[texture_b_in_image_uniform]
	]
	
	run_compute_shader(
		"SSRT: mix",
		mix_shader,
		mix_pipeline,
		uniform_sets,
		push_constant,
	)


func _render_size_changed() -> void:
	print("from: SSRT_CE::_render_size_changed()")
	render_scene_buffers.clear_context(context)
	make_settings_dirty()
	
	
func _settings_changed() -> void:
	print("from: SSRT_CE::_settings_changed()")
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
		
		#int
		settings.blur_kernel_size,
		settings.blur_steps,

		#bool
		settings.depth_affect_ray_length,
		settings.back_face_lighting
	]
	
	settings_ubo = create_uniform_buffer(data)
	settings_ubo_uniform = get_uniform_buffer_uniform(settings_ubo, SETTINGS_UBO_BINDING)
	settings_dirty = false
		
		
func create_textures() -> void:
	const TEXTURE_FORMAT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	
	var texture_a_image : RID = create_simple_texture(context, texture_a, TEXTURE_FORMAT)
	texture_a_in_image_uniform = get_image_uniform(texture_a_image, TEXTURE_IN_IMAGE_BINDING)
	texture_a_out_image_uniform = get_image_uniform(texture_a_image, TEXTURE_OUT_IMAGE_BINDING)
		

func _build_push_constant(p_render_size: Vector2i) -> PackedFloat32Array:
	push_constant= PackedFloat32Array()
	push_constant.push_back(p_render_size.x)
	push_constant.push_back(p_render_size.y)
	push_constant.push_back(0.0)
	push_constant.push_back(0.0)
	return push_constant


func setup_settings() -> void:
	print("from: SSRT_CE::setup_settings()")
	if not settings.s_changed.is_connected(_settings_changed):
		settings.s_changed.connect(_settings_changed)
		
		
func make_settings_dirty() -> void:
	print("from: SSRT_CE::make_settings_dirty()")
	settings_dirty = true
	
	
func _recompile_shaders() -> void:
	print("from: SSRT_CE::_recompile_shaders()")
	trace_shader = create_shader(TRACE_SHADER_PATH)
	mix_shader = create_shader(MIX_SHADER_PATH)
	shaders_dirty = true
