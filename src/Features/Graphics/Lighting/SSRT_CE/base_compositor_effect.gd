@tool
class_name BaseCompositorEffect
extends CompositorEffect

@export_subgroup("Debug")
@export var print_buffer_resize : bool = false
## Use to troubleshoot errors from freeing invalid RIDs.
@export var print_freed_rids : bool = false

const SCENE_DATA_BINDING : int = 0
const COLOR_IMAGE_BINDING : int = 1
const DEPTH_SAMPLER_BINDING : int = 2
const NORMAL_SAMPLER_BINDING : int = 3

var nearest_sampler : RID

var rd : RenderingDevice
var render_data : RenderData
var render_scene_data : RenderSceneData
var render_scene_buffers : RenderSceneBuffers

var render_size := Vector2i.ZERO :
	set(value):
		if value == render_size:
			return
		render_size = value
		_render_size_changed()


var _workgroups := Vector3i.ZERO

var _rids_to_free := {} # {rid : label}


func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		for rid in _rids_to_free:
			if rid.is_valid():
				if print_freed_rids:
					print("freeing RID: %s : %s" % [rid.get_id(), _rids_to_free[rid]])
				rd.free_rid(rid)


func _init():
	_initialize_resource()
	RenderingServer.call_on_render_thread(_initialize_render_base)


func _initialize_render_base() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		return

	nearest_sampler = create_sampler(RenderingDevice.SamplerFilter.SAMPLER_FILTER_NEAREST)

	_initialize_render()


func _render_callback(
		p_effect_callback_type : EffectCallbackType,
		p_render_data : RenderData,
	) -> void:

	if not rd or not p_effect_callback_type == effect_callback_type:
		return

	render_data = p_render_data
	render_scene_buffers = p_render_data.get_render_scene_buffers()
	render_scene_data = p_render_data.get_render_scene_data()

	if not render_scene_buffers or not render_scene_data:
		return

	render_size = render_scene_buffers.get_internal_size()
	if render_size.x == 0 or render_size.y == 0:
		return

	var workgroup_size := _get_workgroup_size()
	_workgroups = Vector3i(
			(render_size.x - 1) / workgroup_size + 1, 
			(render_size.y - 1) / workgroup_size + 1, 
			1
		)

	_render_setup()

	for view in render_scene_buffers.get_view_count():
		_render_view(view)


# ---------------------------------------------------------------------------
# 	PUBLIC FUNCTIONS
# ---------------------------------------------------------------------------

func add_rid_to_free(p_rid : RID, p_label : String = "") -> void:
	_rids_to_free[p_rid] = p_label


## rid.is_valid() returns true for previously freed rids.
## This function is used to track rids as they are freed to prevent errors
## when attempting to free them.
func free_rid(p_rid : RID) -> void:
	_rids_to_free.erase(p_rid)
	if p_rid.is_valid():
		rd.free_rid(p_rid)
		if print_freed_rids:
			print("freeing RID: %s : %s" % [p_rid.get_id(), _rids_to_free[p_rid]])


func create_sampler(
		p_filter : RenderingDevice.SamplerFilter,
		p_repeat_mode := RenderingDevice.SamplerRepeatMode.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE,
	) -> RID:
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = p_filter
	sampler_state.mag_filter = p_filter
	sampler_state.repeat_u = p_repeat_mode
	sampler_state.repeat_v = p_repeat_mode
	sampler_state.repeat_w = p_repeat_mode
	var sampler : RID = rd.sampler_create(sampler_state)
	add_rid_to_free(sampler, "sampler")
	return sampler


func create_shader(p_file_path : String) -> RID:
	var shader_file : RDShaderFile = load(p_file_path)
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader : RID = rd.shader_create_from_spirv(shader_spirv)
	add_rid_to_free(shader, "shader: %s" % p_file_path)
	if not shader.is_valid():
		push_error("from BaseCompositorEffect::create_shader(). Failed to create shader: %s" % p_file_path)
		
	return shader
	

## p_constants is a dictionary of {int : bool/int/float}.
func create_pipeline(p_shader : RID, p_constants := {}) -> RID:
	if not p_shader.is_valid():
		push_error("Shader is not valid")
		return RID()

	var constants : Array[RDPipelineSpecializationConstant] = []
	for key in p_constants:
		assert(typeof(key) == TYPE_INT)
		assert(typeof(p_constants[key]) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL])
		var constant := RDPipelineSpecializationConstant.new()
		constant.constant_id = key
		constant.value = p_constants[key]
		constants.append(constant)

	return rd.compute_pipeline_create(p_shader, constants)


## Creates a unique texture with 1 layer, 1 mipmap, and TEXTURE_SAMPLES_1.
## Returns the image RID.
func create_simple_texture(
		p_context : StringName,
		p_texture_name : StringName,
		p_format : RenderingDevice.DataFormat,
		p_usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		p_texture_size := Vector2i.ZERO,
	) -> RID:

	const TEXTURE_SAMPLES := RenderingDevice.TextureSamples.TEXTURE_SAMPLES_1
	const TEXTURE_LAYER_COUNT : int = 1
	const TEXTURE_MIPMAP_COUNT : int = 1
	const TEXTURE_LAYER : int = 0
	const TEXTURE_MIPMAP : int = 0
	const TEXTURE_IS_UNIQUE : bool = true

	var texture_size := render_size if p_texture_size == Vector2i.ZERO else p_texture_size

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

	# Textures appear to be automatically freed at the time of NOTIFICATION_PREDELETE.
	# Attempting to free the texture's RID will trigger errors.
	# So we will not add its RID to rids_to_free.
	return texture_image




## Individual assignments in a uniform buffer must be aligned to 16 bytes.
## However, you can assign the whole buffer to a struct, and that struct can contain
## elements aligned at 4 bytes (== one 32-bit float, which is the smallest data size
## for uniforms).
##
## Vector4's must be aligned to 16 bytes, so it is best to put them first in the list.
##
## Automatic conversion for Vector2's and Vector3's is not included here.
## We should convert them to Vector4 manually so we can keep track of their alignment.
func create_uniform_buffer(p_data : Array) -> RID:
	var buffer_data : PackedByteArray

	for value in p_data:
		var type := typeof(value)
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
				push_error("[DFOutlineCE:create_uniform_buffer()] Unhandled data type found: %s" % type)
				continue

		buffer_data.append_array(byte_array)

	var size_before := buffer_data.size()

	# Resize to a multiple of 16 bytes.
	if buffer_data.size() % 16:
		var divisor := floori(float(buffer_data.size()) / 16.0)
		buffer_data.resize((divisor + 1) * 16)

	if print_buffer_resize:
		var size_change := buffer_data.size() - size_before
		print("UBO buffer resized from %s to %s." % [size_before, buffer_data.size()])
		print("\tBytes added: %s = %s floats." % [size_change, float(size_change)/4.0])

	var ubo : RID = rd.uniform_buffer_create(buffer_data.size(), buffer_data)
	add_rid_to_free(ubo, "ubo")
	return ubo


func get_uniform_buffer_uniform(p_rid : RID, p_binding : int) -> RDUniform:
	var uniform  := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = p_binding
	uniform.add_id(p_rid)
	return uniform


func get_image_uniform(p_image_rid : RID, p_binding : int = 0) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = p_binding
	uniform.add_id(p_image_rid)
	return uniform


func get_sampler_uniform(
			p_image_rid : RID,
			p_sampler : RID,
			p_binding : int = 0,
		) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = p_binding
	uniform.add_id(p_sampler)
	uniform.add_id(p_image_rid)
	return uniform


## Uniform sets that failed to create on a previous dispatch.
## `UniformSetCacheRD` does not remember failed creations: every cache miss
## retries `uniform_set_create()`, which re-emits the engine ERROR (e.g.
## "Image (binding: 2, index 0) needs the TEXTURE_USAGE_STORAGE_BIT") on every
## frame. The CE memoizes failures here so each unique (viewport, set) pair is
## retried at most once per process. The key is the owning RenderSceneBuffers
## object (stable per viewport, and stable across window resizes) plus the set
## shape, so a set that is valid on one viewport is never skipped because of a
## failure recorded for another viewport's buffers.
var _failed_uniform_set_keys := {}

## The skip diagnostic is printed once per effect instance, not per pass/frame.
var _skipped_pass_reported := false

## Fingerprint of a uniform set for failure-memoization.
##
## The key is the owning RenderSceneBuffers object (its instance ID) plus the
## set's shape (per-uniform type and binding). The RenderSceneBuffers object is
## created once per viewport and reused across window resizes (the scene's
## color/depth/normal textures inside it are freed and recreated with new RIDs
## on every resize, but the object itself survives), so its instance ID is a
## stable per-viewport discriminator: the albedo source SubViewport and the main
## viewport map to different keys, while the same viewport maps to the same key
## every frame AND across resizes.
##
## Deliberately excludes the RIDs of the bound resources (they churn on resize,
## which would make the key change and re-trigger the failing creation), the
## RDUniform objects themselves (rebuilt every frame), and the shader RID (all
## passes share the same set shape, so it adds no discrimination).
func _uniform_set_key(p_set : int, p_uniforms : Array) -> String:
	var shape := ""
	for u in p_uniforms:
		var type := -1
		var binding := -1
		if u is RDUniform:
			type = u.uniform_type
			binding = u.binding
		shape += "%d:%d;" % [type, binding]

	if render_scene_buffers:
		return "%s|%d|%s" % [render_scene_buffers.get_instance_id(), p_set, shape]

	# Defensive fallback (should not happen in practice): no stable viewport
	# discriminator is available, so fall back to the bound RIDs. This key
	# changes on resize, but without it the failing pass could not be skipped.
	var ids := ""
	for u in p_uniforms:
		if u is RDUniform:
			for id in u.get_ids():
				ids += str(id.get_id()) + "/"
	return "null_vp|%d|%s|%s" % [p_set, shape, ids]


## `p_push_constant` takes a PackedFloat32Array and resizes
## it to meet layout requirements. Push constants use std430, so the items
## don't require padding for alignment. But it appears the total size must be
## a multiple of 16 bytes.
func run_compute_shader(
			p_label : String,
			p_shader : RID,
			p_pipeline : RID,
			p_uniform_sets : Array[Array],
			p_push_constant := PackedFloat32Array(),
		) -> void:
	# Resolve and validate the uniform sets before recording any commands.
	# A set is invalid when it cannot be created — most commonly because one
	# of its images lacks TEXTURE_USAGE_STORAGE_BIT: the scene's depth layer
	# is an R32 storage image only when MSAA is on, so a viewport without
	# MSAA (typically the albedo source SubViewport, which shares this world
	# and therefore also runs this effect) gets a D32 depth layer and no
	# valid set. Dispatching there with an unbound set would spam "Uniforms
	# were never supplied for set (N)" every frame, so the pass is skipped.
	var set_rids : Array[RID] = []
	for idx in p_uniform_sets.size():
		var uniforms : Array = p_uniform_sets[idx]
		var key := _uniform_set_key(idx, uniforms)
		if _failed_uniform_set_keys.has(key):
			return
		var set_rid : RID = UniformSetCacheRD.get_cache(p_shader, idx, uniforms)
		if not set_rid.is_valid():
			_failed_uniform_set_keys[key] = true
			_report_skipped_pass(p_label, idx)
			return
		set_rids.append(set_rid)

	rd.draw_command_begin_label(p_label, Color.AQUAMARINE)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, p_pipeline)

	for idx in set_rids.size():
		rd.compute_list_bind_uniform_set(compute_list, set_rids[idx], idx)

	if not p_push_constant.is_empty():
		rd.compute_list_set_push_constant(compute_list, p_push_constant.to_byte_array(), p_push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, _workgroups.x, _workgroups.y, _workgroups.z)
	rd.compute_list_end()
	rd.draw_command_end_label()


func _report_skipped_pass(p_label : String, p_set : int) -> void:
	if _skipped_pass_reported:
		return
	_skipped_pass_reported = true
	push_warning(
		(
			"from: BaseCompositorEffect::run_compute_shader(). "
			+ "Pass '%s' is skipped on this viewport: uniform set %d could not be created because one of its "
			+ "images lacks TEXTURE_USAGE_STORAGE_BIT (typically the depth layer of a viewport without MSAA, "
			+ "e.g. the albedo source SubViewport). The effect stays disabled on that viewport; this warning "
			+ "is printed once."
		) % [p_label, p_set]
	)

## Get Godot's built-in SceneData UBO.
## See https://github.com/godotengine/godot/pull/80214#issuecomment-1953258434
func get_scene_data_ubo() -> RDUniform:
	if not render_scene_data:
		return null

	var scene_data_buffer : RID = render_scene_data.get_uniform_buffer()
	var scene_data_buffer_uniform := RDUniform.new()
	scene_data_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	scene_data_buffer_uniform.binding = SCENE_DATA_BINDING
	scene_data_buffer_uniform.add_id(scene_data_buffer)
	return scene_data_buffer_uniform


func get_color_image_uniform(p_view : int) -> RDUniform:
	var color_image : RID = render_scene_buffers.get_color_layer(p_view)
	var color_image_uniform : RDUniform = get_image_uniform(
			color_image,
			COLOR_IMAGE_BINDING,
		)
	return color_image_uniform
	

func get_depth_image_uniform(p_view : int) -> RDUniform:
	var depth_image : RID = render_scene_buffers.get_depth_layer(p_view)
	var depth_image_uniform: RDUniform = get_image_uniform(depth_image, DEPTH_SAMPLER_BINDING)
	return depth_image_uniform
	

func get_normal_image_uniform() -> RDUniform:
	var normal_image : RID = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")
	var normal_image_uniform: RDUniform = get_image_uniform(normal_image, NORMAL_SAMPLER_BINDING)
	return normal_image_uniform

func get_depth_sampler_uniform(p_view : int, p_sampler : RID) -> RDUniform:
	var depth_image : RID = render_scene_buffers.get_depth_layer(p_view)
	var depth_sampler_uniform : RDUniform = get_sampler_uniform(
			depth_image,
			p_sampler,
			DEPTH_SAMPLER_BINDING,
		)
	return depth_sampler_uniform
	



func get_normal_sampler_uniform(p_view : int, p_sampler : RID) -> RDUniform:
	var normal_image : RID = render_scene_buffers.get_texture(
			"forward_clustered",
			"normal_roughness",
		)
	var normal_sampler_uniform : RDUniform = get_sampler_uniform(
			normal_image,
			p_sampler,
			NORMAL_SAMPLER_BINDING,
	)
	return normal_sampler_uniform


func get_scene_uniform_set(p_view : int) -> Array[RDUniform]:
	return [
			get_scene_data_ubo(),
			get_color_image_uniform(p_view),
			#TODO there was samplers in the original. Not images. And they not workign idk why
			get_depth_image_uniform(p_view),
			get_normal_image_uniform(),
	]



# ---------------------------------------------------------------------------
# 	VIRTUAL FUNCTIONS
# ---------------------------------------------------------------------------

func _get_workgroup_size() -> int:
	return 8


## Virtual function. Called from _init(). Use this function to set up components
## of this resource that are unrelated to the rendering thread.
func _initialize_resource() -> void:
	pass


## Virtual function. Called on render thread after _init(). Use this function
## to set up components associated with the rendering thread, such as samplers,
## shaders and pipelines.
func _initialize_render() -> void:
	pass


## Called at beginning of _render_callback(), after updating render variables
## and after _render_size_changed().
## Use this function to validate and setup textures or uniforms.
func _render_setup() -> void:
	pass


## Called for each view. Run the compute shaders from here.
func _render_view(p_view : int) -> void:
	pass


## Called before _render_setup() if `render_size` has changed.
func _render_size_changed() -> void:
	pass
	
	
func _recompile_shaders() -> void:
	pass
