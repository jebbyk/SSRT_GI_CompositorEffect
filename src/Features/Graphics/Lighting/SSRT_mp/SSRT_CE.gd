@tool
extends CompositorEffect
class_name SSRT_CE_

#TODO GI boost on extreme emitting surface angles
#TODO read GI after engine shadows and lighting, apply GI before engine shadows and lighting
#TODO clear shader RID 
#TODO write trace to separate buffer and blur it before mixing on top of the albedo
#TODO apply blur (cheap denoise) on trace pass and mix it to albedo after

const TRACE_SHADER_FILE_PATH: String = "res://Features/Graphics/Lighting/SSRT_mp/trace.glsl"

@export var settings: SSRTSettings:
	set(value):
		settings = value
		_setup_settings()

var settings_are_dirty: bool = false

var shader_code: String = ""
var shader_is_valid = false
var shader: RID
var pipeline: RID

var trace_shader: RID

var context: StringName = "SSRT_CE"

var texture_a: StringName = "TextureA"
var texture_a_in_image_uniform: RDUniform
var texture_a_out_image_uniform: RDUniform

var push_constant: PackedFloat32Array;
var groups: Vector3i;

var rd : RenderingDevice
var render_scene_data: RenderSceneData
var _rids_to_free := {} # {rid : label}
var render_size: Vector2i = Vector2i.ZERO:
	set(value):
		if value == render_size:
			return
		render_size = value
		_render_size_changed()
var render_scene_buffers: RenderSceneBuffersRD

var ssrt_data_uniform: RDUniform


#Called when this resource is constructed
func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_render)

#Called on a render thread when resource is constructed 
func _initialize_render() -> void:
	rd = RenderingServer.get_rendering_device()
	needs_normal_roughness = true
	
	trace_shader = create_shader(TRACE_SHADER_FILE_PATH)
	
func _render_setup() -> void:
	if not ssrt_data_uniform.is_valid() or settings_are_dirty:
		create_trace_pipeline()
	
#TODO it's from docs. Not quite compatible with what we haav ATM. Have to clear it RID later too
# System notifications, we want to react on the notification that alerts us we are about to be destroyed
#func _notification(what):
	#if what == NOTIFICATION_PREDELETE:
		#if shader.is_valid():
			## Freeing our shader will also free any dependents such as the pipeline!
			#rd.free_rid(shader)

#Called when resource is constructed
func create_shader(p_file_path: String) -> RID:
	var shader_file: RDShaderFile = load(p_file_path)
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader: RID = rd.shader_create_from_spirv(shader_spirv)
	add_rid_to_free(shader, "Shader: %s" % p_file_path)
	return shader
	

func create_pipeline(p_shader: RID, p_constants:= {}) -> RID:
	if not p_shader.is_valid():
		push_error("Shader is not valid")
		return RID()
	
	var constants: Array[RDPipelineSpecializationConstant] = []
	for key in p_constants:
		assert(typeof(key) == TYPE_INT)
		assert(typeof(p_constants[key]) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL])
		var constant: = RDPipelineSpecializationConstant.new()
		constant.constant_id = key
		constant.value = p_constants[key]
		constants.append(constant)
		
	return rd.compute_pipeline_create(p_shader, constants)
			
			
#deprecated
func compile_shader() -> bool:
	if not rd:
		return false

	var shader_file = FileAccess.open(TRACE_SHADER_FILE_PATH, FileAccess.READ)
	var new_shader_code = shader_file.get_as_text()

	if new_shader_code == shader_code:
		return shader_is_valid

	# We don't have a (new) shader?
	if new_shader_code.is_empty():
		return false

	# Out with the old.
	if shader.is_valid():
		rd.free_rid(shader)
		shader = RID()
		pipeline = RID()

	# In with the new.
	var rd_shader_source: RDShaderSource = RDShaderSource.new()
	rd_shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	rd_shader_source.source_compute = new_shader_code
	var rd_shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(rd_shader_source)

	if rd_shader_spirv.compile_error_compute != "":
		push_error(rd_shader_spirv.compile_error_compute)
		push_error("In: " + TRACE_SHADER_FILE_PATH)
		return false

	shader = rd.shader_create_from_spirv(rd_shader_spirv)
	
	if not shader.is_valid():
		return false

	pipeline = rd.compute_pipeline_create(shader)
	return pipeline.is_valid()
	

# Called by the rendering thread every frame.
func _render_callback(p_effect_callback_type, p_render_data):
	shader_is_valid = compile_shader()
	
	#TODO why checking for effect callback type? It is from docs
	if rd and shader_is_valid and p_effect_callback_type == EFFECT_CALLBACK_TYPE_POST_TRANSPARENT :
		render_scene_buffers = p_render_data.get_render_scene_buffers()
		render_scene_data = p_render_data.get_render_scene_data()
		if not render_scene_buffers or not render_scene_data:
			return
		
		render_size = render_scene_buffers.get_internal_size()
		if render_size.x == 0 or render_size.y == 0:
			return
		
		groups = Vector3i(
			(render_size.x - 1) / 8 + 1, 
			(render_size.y - 1) / 8 + 1, 
			1
		)
		
		push_constant = _build_push_constant(render_size)
		
		# Loop through views just in case we're doig stereo rendering. No extra cost if this is mono
		var view_count = render_scene_buffers.get_view_count()
		
		_render_setup()
		
		for view in range(view_count):
			_render_view(view)
			
			
func _render_view(p_view: int) -> void:
	var uniform_set: RID = build_uniform_set(render_scene_buffers, p_view)
	_run_shader("SSRT: Trace", uniform_set, push_constant, groups)


func _build_push_constant(p_render_size: Vector2i) -> PackedFloat32Array:
	push_constant= PackedFloat32Array()
	push_constant.push_back(p_render_size.x)
	push_constant.push_back(p_render_size.y)
	push_constant.push_back(0.0)
	push_constant.push_back(0.0)
	return push_constant


func build_uniform_set(p_render_scene_buffers: RenderSceneBuffersRD, view: int) -> RID:
	# Get the RID for our color image, we will be reading from and writing to it.
	var input_image = p_render_scene_buffers.get_color_layer(view)
	var depth_image = p_render_scene_buffers.get_depth_layer(view)
	var normal_roughness_buffer = p_render_scene_buffers.get_texture("forward_clustered", "normal_roughness")
	var texture_a_image: RID = create_simple_texture(
		"SSRT_CE",
		"TextureA",
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	)

	# Create a uniform set.
	# Ths will be cached; the cache will be cleared if our viewport's configuration is changed
	var color_uniform: RDUniform = create_image_unform(1, input_image)
	var depth_uniform: RDUniform = create_image_unform(2, depth_image)
	var normal_roughness_uniform: RDUniform = create_image_unform(3, normal_roughness_buffer)
	var scene_data_uniform: RDUniform = create_scene_data_uniform()
	ssrt_data_uniform = _create_ssrt_data_uniform()
	texture_a_out_image_uniform = create_image_unform(6, texture_a_image)
				
	return UniformSetCacheRD.get_cache(shader, 0, [scene_data_uniform, color_uniform, depth_uniform, normal_roughness_uniform, ssrt_data_uniform, texture_a_out_image_uniform ])
	
	
func _create_ssrt_data_uniform() -> RDUniform:
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

	var buffer: RID = create_uniform_buffer(data)
	var uniform: RDUniform = get_uniform_buffer_uniform(buffer, 5)
	return uniform
	
	
func _run_shader(p_label: String, uniform_set: RID, push_constant: PackedFloat32Array, groups: Vector3i):
	rd.draw_command_begin_label(p_label, Color.AQUA)
	var compute_list:= rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, groups.x, groups.y, groups.z)
	rd.compute_list_end()
	rd.draw_command_end_label()
	
	
func _setup_settings():
	if not settings.changed.is_connected(make_settings_dirty):
		settings.changed.connect(make_settings_dirty)
	_do_something()
	
	
func make_settings_dirty() -> void:
	settings_are_dirty = true
	
	
func _do_something():
	return#TODO do something?
	


func create_uniform_buffer(p_data: Array) -> RID:
	var buffer_data: PackedByteArray

	for value in p_data:
		var type: int = typeof(value)
		var byte_array : PackedByteArray
		match type:
			TYPE_INT:
				# PackedInt32Array does not convert the values as expected.
				byte_array = PackedFloat32Array([float(value)]).to_byte_array()
			TYPE_BOOL:
				byte_array = PackedFloat32Array([float(value)]).to_byte_array()
			TYPE_FLOAT:
				byte_array = PackedFloat32Array([value]).to_byte_array()
			TYPE_COLOR: 
				byte_array = PackedColorArray([value]).to_byte_array()
			TYPE_VECTOR4:
				byte_array = PackedVector4Array([value]).to_byte_array()
			TYPE_VECTOR4I:
				byte_array = PackedVector4Array([Vector4(value)]).to_byte_array()
			_:
				push_error("[SSRT_TraceCE::create_uniform_buffer()] Unknown data type: %s" % type)
				continue
				
		buffer_data.append_array(byte_array)
	
	if buffer_data.size() % 16:
		var divisor: = floori(float(buffer_data.size()) / 16.0)
		buffer_data.resize((divisor + 1) * 16)
	
	var uniform_buffer: RID = rd.uniform_buffer_create(buffer_data.size(), buffer_data)
	add_rid_to_free(uniform_buffer)
	return uniform_buffer


func get_uniform_buffer_uniform(p_rid: RID, p_binding: int) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = p_binding
	uniform.add_id(p_rid)
	return uniform
	

func add_rid_to_free(p_rid: RID, p_label: String = "") -> void:
	_rids_to_free[p_rid] = p_label


func create_image_unform(binding: int, buffer: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
	
	
func create_scene_data_uniform() -> RDUniform:
	if not render_scene_data:
		return null
	
	var scene_data_buffer: RID = render_scene_data.get_uniform_buffer()
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = 4
	uniform.add_id(scene_data_buffer)
	return uniform


func create_simple_texture(
		p_context: StringName, 
		p_texture_name: StringName, 
		p_format: RenderingDevice.DataFormat, 
		p_usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		p_texture_size: Vector2i = Vector2i.ZERO,
	) -> RID:
		const TEXTURE_SAMPLES := RenderingDevice.TextureSamples.TEXTURE_SAMPLES_1
		const TEXTURE_LAYER_COUNT: int = 1
		const TEXTURE_MIPMAP_COUNT: int = 1
		const TEXTURE_LAYER: int = 0
		const TEXTURE_MIPMAP: int = 0
		const TEXTURE_IS_UNIQUE: bool = true
		
		var texture_size: = render_size if p_texture_size == Vector2i.ZERO else p_texture_size
		
		render_scene_buffers.create_texture(
			p_context,
			p_texture_name,
			p_format,
			p_usage_bits,
			TEXTURE_SAMPLES,
			texture_size,
			TEXTURE_LAYER_COUNT,
			TEXTURE_MIPMAP_COUNT,
			TEXTURE_IS_UNIQUE,
			false
		)

		var texture_image : RID = render_scene_buffers.get_texture_slice(
			p_context,
			p_texture_name,
			TEXTURE_LAYER,
			TEXTURE_MIPMAP,
			TEXTURE_LAYER_COUNT,
			TEXTURE_MIPMAP_COUNT,
		)
		
		return texture_image


func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		for rid in _rids_to_free:
			if rid.is_valid():
				rd.free_rid(rid)
							

## Called before _render_setup() if `render_size` has changed.
func _render_size_changed() -> void:
	pass
	
