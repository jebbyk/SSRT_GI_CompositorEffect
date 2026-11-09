@tool
class_name SSRT_CE
extends BaseCompositorEffect

#TODO improve bad sample canceling (on alligning surfaces)
#TODO use separate z_thickness for AO and bounce (?)
#TODO reduce self-litting\occluding
#TODO use includes at full potential
#TODO advanced denoise (ray cone spot i.e. far samples are wider) (?)
#TODO more advanced denoise with samples accumulation from several frames
#TODO even more advanced denosie with motion vectors taken into account
#TODO optimize with BVH (ye it is possible to build one on a GPU)
#TODO rays miss to sky color and ground color
#TODO ray miss to scene skybox
#TODO retrieve metalicity buffer and use it to proper reflections
#TODO make it compatible with upscaling (screen quad version remains sharp even with fsr2.1 x0.5)
#TODO use multiple cameras setup to capture offscreen things (?)
#TODO use scene voxelization and voxel tracing (maybe as separate CE) (the key difference from original is an actual tracing)

##Shaders live next to this script, so the whole folder can be dropped anywhere in the project.
##(get_script() is unavailable at parse time, hence a function instead of consts.)
func _shader(p_name: String) -> String:
	return get_script().resource_path.get_base_dir().path_join("shaders/").path_join(p_name)

#Debug MV pass (set 0): engine velocity texture, bound as a sampler.
const DEBUG_MV_VELOCITY_BINDING := 3

const USE_DEBUG_IMAGE = false

#Set 1 bindings
const SETTINGS_UBO_BINDING := 0
const DEBUG_IMAGE_BINDING := 1

#set 2 binding
const TEXTURE_IN_IMAGE_BINDING := 0
const TEXTURE_OUT_IMAGE_BINDING := 1

#Specialization constant bindings
const BLUR_OFFSET_CONSTANT_BINDING: int = 0
const MIX_ALBEDO_GI_CONSTANT: int = 0
const DEBUG_ALBEDO_GI_CONSTANT: int = 0

#Mix pass: set 1 bindings
const ALBEDO_TEXTURE_BINDING := 1
const HISTORY_IMAGE_BINDING := 2
#Ping-pong write partner of the history texture (bound by both EMA and box passes).
const HISTORY_WRITE_BINDING := 3
#Validation depth for disocclusion revalidation, ping-ponged with the history.
const HISTORY_DEPTH_BINDING := 4
const HISTORY_DEPTH_WRITE_BINDING := 5

#Per-object velocity buffer for reprojection; the shader falls back to the
#camera-only path on the engine's (-1,-1) sentinel (pixels it left unwritten).
const MIX_VELOCITY_BINDING := 4

#EMA history texture names: ping-pong pair + matching r32f validation-depth pair.
const HISTORY_TEXTURE_NAME: StringName = &"SSRT_History"
const HISTORY_WRITE_TEXTURE_NAME: StringName = &"SSRT_HistoryWrite"
const HISTORY_DEPTH_TEXTURE_NAME: StringName = &"SSRT_HistoryDepth"
const HISTORY_DEPTH_WRITE_TEXTURE_NAME: StringName = &"SSRT_HistoryDepthWrite"

@export_tool_button("Recompile shaders", "Callable") var recompile_shaders_action = _recompile_shaders

@export  var settings : SSRTSettings :
	set(value):
		settings = value
		setup_settings()

## Shared handoff resource filled by SSRTAlbedoSource (albedo_source_viewport.gd).
## When set, the GI bounce is modulated by the scene's unlit albedo (from that
## viewport's render target) instead of the already-lit scene color.
## Typed as Resource because Godot 4.7 does not allow Node-typed exports on
## Resource classes, and the handoff itself holds no Node references.
@export var albedo_handoff : Resource :
	set(value):
		if albedo_handoff == value:
			return
		albedo_handoff = value
		shaders_dirty = true

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
var blur_pipelines : Array

var mix_shader : RID
var mix_pipeline : RID

var mix_ema_shader : RID
var mix_ema_pipeline : RID
var mix_box8_shader : RID
var mix_box8_pipeline : RID
var mix_box16f_shader : RID
var mix_box16f_pipeline : RID
var debug_mv_shader : RID
var debug_mv_pipeline : RID
var debug_albedo_shader : RID
var debug_albedo_pipeline : RID
var history_image_uniform : RDUniform
var history_write_uniform : RDUniform
var history_depth_uniform : RDUniform
var history_depth_write_uniform : RDUniform
var accumulation_weight : float = 1.0

#Box history per viewport (viewports sharing the world may have different rasters):
#{vp_key: {textures: [RID, RID], depth_textures: [RID, RID], swap: int, tex_size: Vector2i}}.
#Manual 3D RIDs (depth = N slices) — create_simple_texture is 2D-only.
#Reprojection on → two ping-pong textures (an in-place shift would race across invocations);
#off → second RID invalid, swap stays 0.
var _box_history_by_vp : Dictionary = {}
#Rolling box frame counter per viewport (slot = frame % N; first frame averages itself only).
var _box_frame_by_vp : Dictionary = {}
#Last size acted on, per viewport: the shared render_size flips between rasters and would retrigger the handler every frame.
var _size_handled_by_vp : Dictionary = {}
var box_slot_index : float = 0.0
var box_valid_count : float = 1.0

#EMA history written at least once, per viewport: first frame must not read uninitialized memory.
var _ema_valid_by_vp : Dictionary = {}
#EMA ping-pong split per viewport (0: read History, 1: read HistoryWrite); flipped after each dispatch.
var _ema_swap_by_vp : Dictionary = {}

#Warn once while a box mode falls back to plain mix (no 3D history texture).
var _box_mode_warned : bool = false

#Warn once when _render_setup is skipped on an MSAA-less viewport.
var _msaaless_setup_reported : bool = false

#Memoized MSAA-less detection per viewport: the probe makes the engine print the STORAGE_BIT error, so it runs at most once.
var _msaaless_by_vp : Dictionary = {}

#Albedo (unlit) source state, see albedo_handoff.gd
var albedo_sampler : RID
var albedo_placeholder : RID
var albedo_rd_texture : RID

var push_constant: PackedFloat32Array;

var settings_dirty: bool = false
var shaders_dirty: bool = false

#called once on resource creation (when effect is added to list, or when scene loaded)
func _initialize_resource() -> void:
	#print("from: SSRT_CE::_initialize_resource()")
	if not settings:
		settings = SSRTSettings.new()
		setup_settings()
	
	access_resolved_depth = true
	access_resolved_color = true
	needs_normal_roughness = true
	#Required for history reprojection: makes the engine fill the prev-frame
	#camera section of the scene UBO (prev_data), used by mix_*.glsl.
	needs_motion_vectors = true
		
#called once on resource creation (when effect is added to list, or when scene loaded) after resource is initialized
func _initialize_render() -> void: 
	#print("from: SSRT_CE::_initialize_render()")
	albedo_sampler = create_sampler(RenderingDevice.SamplerFilter.SAMPLER_FILTER_LINEAR)
	_create_albedo_placeholder()
	_recompile_shaders()
		
	
#called every frame before executing code for each view
func _render_setup() -> void:
	#Pipelines first: the albedo-source detection below tests the scene set against the trace shader.
	if not settings_ubo.is_valid() or settings_dirty or shaders_dirty:
		#print("from: SSRT_CE::_render_setup(). msg: Settings are dirty")
		create_settings_uniform_buffer()
		create_trace_pipeline()
		create_blur_pipelines()
		create_mix_pipeline()
		create_mix_ema_pipeline()
		create_mix_box8_pipeline()
		create_mix_box16f_pipeline()
		create_debug_mv_pipeline()
		create_debug_albedo_pipeline()
		shaders_dirty = false
		_report_vram_estimate()
	
	#An MSAA-less viewport in this world gets a D32 depth layer with no STORAGE_BIT, so
	#its scene set can't be built. Skip setup there: it would publish its raster to the
	#handoff (the main viewport sizes the albedo target from it). Its passes are already
	#skipped by run_compute_shader(). (The albedo source SubViewport no longer reaches
	#this effect at all — its camera carries an empty compositor, see SSRTAlbedoSource.)
	if _is_msaaless_viewport():
		if not _msaaless_setup_reported:
			_msaaless_setup_reported = true
			push_warning(
				"SSRT_CE: render callback is on an MSAA-less viewport "
				+ "(scene set has no STORAGE_BIT depth); setup skipped so the shared "
				+ "ping-pong stays at the main viewport's raster."
			)
		return
	
	#Publish this viewport's raster; SSRTAlbedoSource sizes its target from it.
	#Written render-thread / read main-thread.
	if albedo_handoff:
		albedo_handoff.render_size = render_size
	
	_resolve_albedo_texture()
	
	if not render_scene_buffers.has_texture(context, texture_a):
		create_textures()
	
	#N=1 = accumulation off (weight 1.0). N>1: box-matched, history ~95% replaced by N frames.
	var n = float(settings.accumulation_frames)
	accumulation_weight = 1.0 if n <= 1.0 else 1.0 - pow(0.05, 1.0 / n)
	
	if _ema_active():
		var vp_key : int = render_scene_buffers.get_instance_id()
		if not render_scene_buffers.has_texture(context, HISTORY_TEXTURE_NAME) \
		   or not render_scene_buffers.has_texture(context, HISTORY_WRITE_TEXTURE_NAME) \
		   or not render_scene_buffers.has_texture(context, HISTORY_DEPTH_TEXTURE_NAME) \
		   or not render_scene_buffers.has_texture(context, HISTORY_DEPTH_WRITE_TEXTURE_NAME):
			_create_history_texture()
			#Fresh ping-pong pair: define the first read/write split.
			_ema_swap_by_vp[vp_key] = 0
		else:
			#Rebind every frame: the split flips per dispatch, and a mode switch may leave freed RIDs in the uniforms.
			_rebind_ema_uniforms(vp_key)
	elif _box_wanted():
		_ensure_box_history()
		
	push_constant = _build_push_constant(render_size)#TODO no need to do it every frame?


#True when this callback runs on an MSAA-less viewport of the world (its D32 depth layer
#lacks STORAGE_BIT, so the scene set can't be built) — the same signal run_compute_shader()
#uses to skip passes. The albedo source SubViewport is excluded upstream (its camera's
#empty compositor), so this now covers other plain SubViewports.
func _is_msaaless_viewport() -> bool:
	var vp_key : String = str(render_scene_buffers.get_instance_id()) if render_scene_buffers else "null_vp"
	if _msaaless_by_vp.has(vp_key):
		return _msaaless_by_vp[vp_key]
	if not trace_shader.is_valid():
		return false
	#A failing get_cache() makes the engine print the usage-flag error (hence the once-per-viewport memo above).
	var scene_set := get_scene_uniform_set(0)
	var is_msaaless := not UniformSetCacheRD.get_cache(trace_shader, 0, scene_set).is_valid()
	_msaaless_by_vp[vp_key] = is_msaaless
	return is_msaaless


func create_trace_pipeline() -> void:
	if not trace_shader.is_valid():
		push_error("from: SSRT_CE::create_trace_pipeline(). msg: Trace shader is not valid")
		
	if rd.compute_pipeline_is_valid(trace_pipeline):
		rd.free_rid(trace_pipeline)
		
	trace_pipeline = create_pipeline(trace_shader)
	
	
func create_blur_pipelines() -> void:
	#print("from: SSRT_CE::create_blur_pipelines()")
	for i in blur_pipelines.size():
		if rd.compute_pipeline_is_valid(blur_pipelines[i]):
			rd.free_rid(blur_pipelines[i])
		
	blur_pipelines.clear()
	
	var offset : int = settings.blur_kernel_size
	for i in settings.blur_steps:
		create_blur_pipeline(offset)
		offset *= 3
	
	
func create_blur_pipeline(offset : int) -> void:
	#print("from: SSRT_CE::create_blur_pipeline() offset: %s" % offset)
	if not blur_shader.is_valid():
		push_error("from: SSRT_CE::create_blur_pipeline(). msg: Blur shader is not valid")
		
	#TODO maybe use push constant for offsets instead?
	blur_pipelines.append(create_pipeline(blur_shader, {BLUR_OFFSET_CONSTANT_BINDING : offset}))
	

func create_mix_pipeline() -> void:
	if not mix_shader.is_valid():
		push_error("from: SSRT_CE:create_mix_pipeline(). msg: Mix shader is not valid")
		
	if rd.compute_pipeline_is_valid(mix_pipeline):
		rd.free_rid(mix_pipeline)
	
	var constants := {}
	if albedo_handoff:
		constants[MIX_ALBEDO_GI_CONSTANT] = true
	mix_pipeline = create_pipeline(mix_shader, constants)


func create_mix_ema_pipeline() -> void:
	if not mix_ema_shader.is_valid():
		push_error("from: SSRT_CE::create_mix_ema_pipeline(). msg: Mix EMA shader is not valid")
		
	if rd.compute_pipeline_is_valid(mix_ema_pipeline):
		rd.free_rid(mix_ema_pipeline)
	
	var constants := {}
	if albedo_handoff:
		constants[MIX_ALBEDO_GI_CONSTANT] = true
	mix_ema_pipeline = create_pipeline(mix_ema_shader, constants)


func create_mix_box8_pipeline() -> void:
	if not mix_box8_shader.is_valid():
		push_error("from: SSRT_CE::create_mix_box8_pipeline(). msg: Mix BOX8 shader is not valid")
		
	if rd.compute_pipeline_is_valid(mix_box8_pipeline):
		rd.free_rid(mix_box8_pipeline)
	
	var constants := {}
	if albedo_handoff:
		constants[MIX_ALBEDO_GI_CONSTANT] = true
	mix_box8_pipeline = create_pipeline(mix_box8_shader, constants)


func create_mix_box16f_pipeline() -> void:
	if not mix_box16f_shader.is_valid():
		push_error("from: SSRT_CE::create_mix_box16f_pipeline(). msg: Mix BOX16F shader is not valid")
		
	if rd.compute_pipeline_is_valid(mix_box16f_pipeline):
		rd.free_rid(mix_box16f_pipeline)
	
	var constants := {}
	if albedo_handoff:
		constants[MIX_ALBEDO_GI_CONSTANT] = true
	mix_box16f_pipeline = create_pipeline(mix_box16f_shader, constants)


func create_debug_mv_pipeline() -> void:
	if not debug_mv_shader.is_valid():
		push_error("from: SSRT_CE::create_debug_mv_pipeline(). msg: Debug MV shader is not valid")
		
	if rd.compute_pipeline_is_valid(debug_mv_pipeline):
		rd.free_rid(debug_mv_pipeline)
	
	debug_mv_pipeline = create_pipeline(debug_mv_shader)


func create_debug_albedo_pipeline() -> void:
	if not debug_albedo_shader.is_valid():
		push_error("from: SSRT_CE::create_debug_albedo_pipeline(). msg: Debug albedo shader is not valid")
		
	if rd.compute_pipeline_is_valid(debug_albedo_pipeline):
		rd.free_rid(debug_albedo_pipeline)
	
	var constants := {}
	if albedo_handoff:
		constants[DEBUG_ALBEDO_GI_CONSTANT] = true
	debug_albedo_pipeline = create_pipeline(debug_albedo_shader, constants)


func _ema_active() -> bool:
	return settings.accumulation_mode == SSRTSettings.AccumulationMode.EMA


func _create_history_texture() -> void:
	#EMA ping-pong pair + r32f validation-depth pair, in the shared context (freed by clear_context on size change).
	var format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	if not render_scene_buffers.has_texture(context, HISTORY_TEXTURE_NAME):
		var history_image : RID = create_simple_texture(
			context, HISTORY_TEXTURE_NAME, format
		)
		history_image_uniform = get_image_uniform(history_image, HISTORY_IMAGE_BINDING)
	if not render_scene_buffers.has_texture(context, HISTORY_WRITE_TEXTURE_NAME):
		var history_write_image : RID = create_simple_texture(
			context, HISTORY_WRITE_TEXTURE_NAME, format
		)
		history_write_uniform = get_image_uniform(history_write_image, HISTORY_WRITE_BINDING)
	#r32f validation depth, ping-ponged in lockstep: the surface depth each estimate was accumulated for.
	var depth_format := RenderingDevice.DATA_FORMAT_R32_SFLOAT
	if not render_scene_buffers.has_texture(context, HISTORY_DEPTH_TEXTURE_NAME):
		var history_depth_image : RID = create_simple_texture(
			context, HISTORY_DEPTH_TEXTURE_NAME, depth_format
		)
		history_depth_uniform = get_image_uniform(history_depth_image, HISTORY_DEPTH_BINDING)
	if not render_scene_buffers.has_texture(context, HISTORY_DEPTH_WRITE_TEXTURE_NAME):
		var history_depth_write_image : RID = create_simple_texture(
			context, HISTORY_DEPTH_WRITE_TEXTURE_NAME, depth_format
		)
		history_depth_write_uniform = get_image_uniform(history_depth_write_image, HISTORY_DEPTH_WRITE_BINDING)


func _rebind_ema_uniforms(p_vp_key: int) -> void:
	#Ping-pong split: one texture read, the other written; flipped after each dispatch.
	var read_name : StringName = HISTORY_TEXTURE_NAME
	var write_name : StringName = HISTORY_WRITE_TEXTURE_NAME
	var read_depth_name : StringName = HISTORY_DEPTH_TEXTURE_NAME
	var write_depth_name : StringName = HISTORY_DEPTH_WRITE_TEXTURE_NAME
	if _ema_swap_by_vp.get(p_vp_key, 0) == 1:
		read_name = HISTORY_WRITE_TEXTURE_NAME
		write_name = HISTORY_TEXTURE_NAME
		read_depth_name = HISTORY_DEPTH_WRITE_TEXTURE_NAME
		write_depth_name = HISTORY_DEPTH_TEXTURE_NAME
	history_image_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, read_name, 0, 0, 1, 1),
		HISTORY_IMAGE_BINDING
	)
	history_write_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, write_name, 0, 0, 1, 1),
		HISTORY_WRITE_BINDING
	)
	history_depth_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, read_depth_name, 0, 0, 1, 1),
		HISTORY_DEPTH_BINDING
	)
	history_depth_write_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, write_depth_name, 0, 0, 1, 1),
		HISTORY_DEPTH_WRITE_BINDING
	)


func _box_wanted() -> bool:
	var mode := settings.accumulation_mode
	return mode == SSRTSettings.AccumulationMode.BOX8 or mode == SSRTSettings.AccumulationMode.BOX16F


func _reprojection_enabled() -> float:
	return 1.0 if settings.reprojection_enabled else 0.0


func _ensure_box_history() -> void:
	#This viewport's N-frame 3D history (rolling slot = frame % N).
	#A failed create leaves no entry → the mix pass falls back to plain mix.
	if render_size.x <= 0 or render_size.y <= 0:
		return
	var vp_key : int = render_scene_buffers.get_instance_id()
	var entry : Variant = _box_history_by_vp.get(vp_key)
	if entry != null and entry.tex_size == render_size:
		_rebind_box_uniforms(entry)
		return
	if entry != null:
		_drop_box_history_entry(vp_key)

	var count : int = 2 if settings.reprojection_enabled else 1
	var color_format : RenderingDevice.DataFormat = \
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM \
		if settings.accumulation_mode == SSRTSettings.AccumulationMode.BOX8 \
		else RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var textures : Array = []
	var depth_textures : Array = []
	for i in count:
		#Color history + its r32f validation-depth twin, same N slices, ping-ponged in lockstep.
		var texture : RID = _create_box_3d(color_format)
		var depth_texture : RID = _create_box_3d(RenderingDevice.DATA_FORMAT_R32_SFLOAT)
		if not texture.is_valid() or not depth_texture.is_valid():
			#Partially-created RIDs stay in _rids_to_free (predelete frees them); no entry → plain-mix fallback.
			push_error("from: SSRT_CE::_ensure_box_history(). msg: 3D history texture creation failed (%dx%dxN, N=%d, pair %d of %d)." % [
				render_size.x,
				render_size.y,
				settings.accumulation_frames,
				i + 1, count,
			])
			return
		add_rid_to_free(texture, "box history texture")
		add_rid_to_free(depth_texture, "box history depth texture")
		textures.append(texture)
		depth_textures.append(depth_texture)
	while textures.size() < 2:
		textures.append(RID())
		depth_textures.append(RID())
	_box_history_by_vp[vp_key] = {
		"textures": textures,
		"depth_textures": depth_textures,
		"swap": 0,
		"tex_size": render_size,
	}
	_rebind_box_uniforms(_box_history_by_vp[vp_key])


func _create_box_3d(p_format: RenderingDevice.DataFormat) -> RID:
	var format := RDTextureFormat.new()
	format.format = p_format
	format.width = render_size.x
	format.height = render_size.y
	#TEXTURE_TYPE_3D extent is `depth` (drivers force array_layers to 1); N slices live there.
	format.depth = settings.accumulation_frames
	format.array_layers = 1
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var view := RDTextureView.new()
	return rd.texture_create(format, view, [])


func _rebind_box_uniforms(p_entry: Variant) -> void:
	var t0 : RID = p_entry.textures[0]
	var t1 : RID = p_entry.textures[1]
	var d0 : RID = p_entry.depth_textures[0]
	var d1 : RID = p_entry.depth_textures[1]
	var read : RID = t0
	var write : RID = t0
	var depth_read : RID = d0
	var depth_write : RID = d0
	if t1.is_valid():
		read = t0 if p_entry.swap == 0 else t1
		write = t1 if p_entry.swap == 0 else t0
		depth_read = d0 if p_entry.swap == 0 else d1
		depth_write = d1 if p_entry.swap == 0 else d0
	history_image_uniform = get_image_uniform(read, HISTORY_IMAGE_BINDING)
	history_write_uniform = get_image_uniform(write, HISTORY_WRITE_BINDING)
	history_depth_uniform = get_image_uniform(depth_read, HISTORY_DEPTH_BINDING)
	history_depth_write_uniform = get_image_uniform(depth_write, HISTORY_DEPTH_WRITE_BINDING)


func _drop_box_history_entry(p_vp_key: int) -> void:
	var entry : Variant = _box_history_by_vp.get(p_vp_key)
	if entry == null:
		return
	_box_history_by_vp.erase(p_vp_key)
	for textures in [entry.textures, entry.depth_textures]:
		for texture in textures:
			if texture.is_valid():
				#free_rid is render-thread-only, but settings/size changes and predelete arrive on the main
				#thread — free there, erased from _rids_to_free first so predelete doesn't double-free.
				_rids_to_free.erase(texture)
				RenderingServer.call_on_render_thread(_free_box_history_rid.bind(texture))


static func _free_box_history_rid(rid: RID) -> void:
	var device := RenderingServer.get_rendering_device()
	if device and rid.is_valid():
		device.free_rid(rid)


func _free_box_history() -> void:
	for vp_key in _box_history_by_vp.keys():
		_drop_box_history_entry(vp_key)


func _report_vram_estimate() -> void:
	#Informational VRAM footprint of the history buffers.
	var w : int = render_size.x
	var h : int = render_size.y
	var frames : int = settings.accumulation_frames if not _ema_active() else 1
	var copies : int = 2 if _ema_active() or (_box_wanted() and settings.reprojection_enabled) else 1
	var bytes : int = w * h * frames * settings.bytes_per_pixel() * copies
	#Both modes carry the r32f validation-depth buffer (4 bytes/px per slot).
	if _ema_active() or _box_wanted():
		bytes += w * h * frames * 4 * copies
	var mode_name : String = SSRTSettings.AccumulationMode.keys()[settings.accumulation_mode]
	print("SSRT_CE: temporal history ≈ %.1f MB (%s, N=%d, %dx%d%s)" % [
		bytes / 1048576.0,
		mode_name,
		settings.accumulation_frames,
		w, h,
		" x2 ping-pong" if copies == 2 else "",
	])

	
func _render_view(p_view : int) -> void:
	#print("from: SSRT_CE::_render_view()")
	var scene_uniform_set : Array[RDUniform] = get_scene_uniform_set(p_view)
	var settings_uniform_set : Array[RDUniform] = [settings_ubo_uniform]
	
	#Per-object velocity buffer for the mix passes' reprojection. The defensive mix.glsl pass
	#keeps the plain set (declares no velocity).
	var velocity_image : RID = render_scene_buffers.get_velocity_texture()
	var velocity_bind : RID = velocity_image
	if not velocity_bind.is_valid():
		velocity_bind = albedo_placeholder
	var mix_scene_set : Array[RDUniform] = scene_uniform_set.duplicate()
	mix_scene_set.append(get_sampler_uniform(velocity_bind, nearest_sampler, MIX_VELOCITY_BINDING))
	
	#Debug overlay replaces the effect output; trace/blur/mix are unused. Reuses the velocity buffer above.
	if settings.debug_view == SSRTSettings.DebugView.MOTION_VECTORS:
		var debug_mv_set : Array[RDUniform] = [
			get_scene_data_ubo(),
			get_color_image_uniform(p_view),
			get_depth_image_uniform(p_view),
			get_sampler_uniform(velocity_bind, nearest_sampler, DEBUG_MV_VELOCITY_BINDING),
		]
		run_compute_shader(
			"SSRT: Debug MV",
			debug_mv_shader,
			debug_mv_pipeline,
			[debug_mv_set],
			push_constant,
		)
		return
	
	#Unlit albedo overlay: writes exactly what the GI bounce multiplies by (the source
	#viewport's albedo, else the lit-color fallback). Reuses the mix pass' albedo binding.
	if settings.debug_view == SSRTSettings.DebugView.UNLIT_ALBEDO:
		var albedo_bind : RID = albedo_rd_texture
		if not albedo_bind.is_valid():
			albedo_bind = albedo_placeholder
		var debug_albedo_set_0 : Array[RDUniform] = [
			get_scene_data_ubo(),
			get_color_image_uniform(p_view),
			get_depth_image_uniform(p_view),
		]
		var debug_albedo_set_1 : Array[RDUniform] = [
			get_sampler_uniform(albedo_bind, albedo_sampler, ALBEDO_TEXTURE_BINDING),
		]
		run_compute_shader(
			"SSRT: Debug Albedo",
			debug_albedo_shader,
			debug_albedo_pipeline,
			[debug_albedo_set_0, debug_albedo_set_1],
			push_constant,
		)
		return
	
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
	#TODO create SwapBufferObject class or use someting similar if it exists
	var in_image_uniform : RDUniform = texture_a_in_image_uniform
	var out_image_uniform : RDUniform = texture_b_out_image_uniform
	
	for i in blur_pipelines.size():
		
		var blur_pipeline : RID = blur_pipelines[i]
		
		if not blur_pipeline.is_valid():
			push_error("from: SSRT_CE::_render_view(). msg: No valid blur pass pipeline found for blur step: %s" % i)
			continue
		
		uniform_sets = [
			scene_uniform_set,
			settings_uniform_set,
			[in_image_uniform, out_image_uniform]
		]
		
		run_compute_shader(
			"SSRT: blur",
			blur_shader,
			blur_pipeline,
			uniform_sets,
			push_constant,
		)
		
		if out_image_uniform == texture_a_out_image_uniform:
			in_image_uniform = texture_a_in_image_uniform
			out_image_uniform = texture_b_out_image_uniform
		else:
			in_image_uniform = texture_b_in_image_uniform
			out_image_uniform = texture_a_out_image_uniform
		
	
	#overlay pass
	#The albedo descriptor is bound unconditionally (declared in the shader in both
	#pipeline variants): use the black placeholder when there is no handoff or the
	#albedo viewport has no render target yet (first frame). While albedo_size is 0
	#the shader skips sampling and keeps the legacy lit-color modulation.
	var mix_uniforms : Array[RDUniform] = [in_image_uniform]
	var albedo_bind : RID = albedo_rd_texture
	if not albedo_bind.is_valid():
		albedo_bind = albedo_placeholder
	mix_uniforms.append(get_sampler_uniform(albedo_bind, albedo_sampler, ALBEDO_TEXTURE_BINDING))
	
	if _ema_active():
		#Bind history (b2), its ping-pong partner (b3) and the validation-depth pair (b4/b5).
		mix_uniforms.append(history_image_uniform)
		mix_uniforms.append(history_write_uniform)
		mix_uniforms.append(history_depth_uniform)
		mix_uniforms.append(history_depth_write_uniform)
		var vp_key : int = render_scene_buffers.get_instance_id()
		var history_valid : float = 1.0 if _ema_valid_by_vp.get(vp_key, false) else 0.0
		#Extend the base 16-byte push constant to 36 (weight/valid/reproj/depth-threshold/bilinear) — must match the shader exactly.
		var ema_push : PackedFloat32Array = push_constant.duplicate()
		ema_push.push_back(accumulation_weight)
		ema_push.push_back(history_valid)
		ema_push.push_back(_reprojection_enabled())
		ema_push.push_back(settings.reproj_depth_threshold)
		ema_push.push_back(1.0 if settings.bilinear_reprojection else 0.0)
		uniform_sets = [
			mix_scene_set,
			mix_uniforms
		]
		run_compute_shader(
			"SSRT: mix (EMA)",
			mix_ema_shader,
			mix_ema_pipeline,
			uniform_sets,
			ema_push,
		)
		#The albedo viewport auto-skips this pass — flagging/flipping there is harmless.
		_ema_valid_by_vp[vp_key] = true
		_ema_swap_by_vp[vp_key] = 1 - _ema_swap_by_vp.get(vp_key, 0)
	elif _box_wanted() and _box_history_by_vp.has(render_scene_buffers.get_instance_id()):
		#Flat N-frame average: current frame → rolling slot, average of the last min(frame+1, N) slots.
		var is_box8 : bool = settings.accumulation_mode == SSRTSettings.AccumulationMode.BOX8
		var box_shader : RID = mix_box8_shader if is_box8 else mix_box16f_shader
		var box_pipeline : RID = mix_box8_pipeline if is_box8 else mix_box16f_pipeline
		mix_uniforms.append(history_image_uniform)
		mix_uniforms.append(history_write_uniform)
		mix_uniforms.append(history_depth_uniform)
		mix_uniforms.append(history_depth_write_uniform)
		var vp_key : int = render_scene_buffers.get_instance_id()
		var frame : int = _box_frame_by_vp.get(vp_key, -1) + 1
		var n : int = settings.accumulation_frames
		box_slot_index = float(frame % n)
		box_valid_count = float(mini(frame + 1, n))
		_box_frame_by_vp[vp_key] = frame
		#Extend the base 16-byte push constant to 36 (slot/count/reproj/depth-threshold/bilinear) — must match the shader exactly.
		var box_push : PackedFloat32Array = push_constant.duplicate()
		box_push.push_back(box_slot_index)
		box_push.push_back(box_valid_count)
		box_push.push_back(_reprojection_enabled())
		box_push.push_back(settings.reproj_depth_threshold)
		box_push.push_back(1.0 if settings.bilinear_reprojection else 0.0)
		uniform_sets = [
			mix_scene_set,
			mix_uniforms
		]
		run_compute_shader(
			"SSRT: mix (BOX8)" if is_box8 else "SSRT: mix (BOX16F)",
			box_shader,
			box_pipeline,
			uniform_sets,
			box_push,
		)
		#Advance the ping-pong swap (meaningless on a viewport whose pass is skipped).
		var entry : Variant = _box_history_by_vp.get(vp_key)
		if entry.textures[1].is_valid():
			entry.swap = 1 - entry.swap
	else:
		#Box mode without a 3D history: composite the per-frame estimate.
		if not _box_mode_warned:
			var mode_name : String = SSRTSettings.AccumulationMode.keys()[settings.accumulation_mode]
			push_warning("from: SSRT_CE::_render_view(). msg: Temporal accumulation is unavailable in mode %s (no 3D history texture), using no temporal accumulation." % mode_name)
			_box_mode_warned = true
		uniform_sets = [
			scene_uniform_set,
			mix_uniforms
		]
		run_compute_shader(
			"SSRT: mix",
			mix_shader,
			mix_pipeline,
			uniform_sets,
			push_constant,
		)


func _render_size_changed() -> void:
	#print("from: SSRT_CE::_render_size_changed()")
	var vp_key : int = render_scene_buffers.get_instance_id()
	#The shared render_size flips between viewport rasters; act only on this viewport's real change.
	if _size_handled_by_vp.get(vp_key) == render_size:
		return
	_size_handled_by_vp[vp_key] = render_size
	render_scene_buffers.clear_context(context)
	#Drop this viewport's box history + counter so the recreated history isn't read before its first write.
	_ema_valid_by_vp.erase(vp_key)
	_ema_swap_by_vp.erase(vp_key)
	_box_frame_by_vp.erase(vp_key)
	_drop_box_history_entry(vp_key)
	_box_mode_warned = false
	make_settings_dirty()
	
	
func _settings_changed() -> void:
	#print("from: SSRT_CE::_settings_changed()")
	#Main thread (inspector): no direct RID touches, no clear_context (render-thread-only; a
	#main-thread clear would leak). Stale contents are harmless via the validity flags reset
	#below; size changes clear via _render_size_changed.
	_ema_valid_by_vp.clear()
	_ema_swap_by_vp.clear()
	_box_frame_by_vp.clear()
	_box_mode_warned = false
	_free_box_history()
	make_settings_dirty()


func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		#Deferred frees are static RID-only callables, safe after self is gone.
		_free_box_history()
	super._notification(what)


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
		settings.normal_treshold,
		settings.blur_normal_treshold,
		settings.blur_plane_treshold,
		
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
	
	var texture_b_image : RID = create_simple_texture(context, texture_b, TEXTURE_FORMAT)
	texture_b_in_image_uniform = get_image_uniform(texture_b_image, TEXTURE_IN_IMAGE_BINDING)
	texture_b_out_image_uniform = get_image_uniform(texture_b_image, TEXTURE_OUT_IMAGE_BINDING)


func _resolve_albedo_texture() -> void:
	if not albedo_handoff:
		albedo_rd_texture = RID()
		return

	var viewport_rid : RID = albedo_handoff.viewport_rid
	if not viewport_rid.is_valid():
		albedo_rd_texture = RID()
		return

	var rs_texture : RID = RenderingServer.viewport_get_texture(viewport_rid)
	if not rs_texture.is_valid():
		albedo_rd_texture = RID()
		return

	albedo_rd_texture = RenderingServer.texture_get_rd_texture(rs_texture, false)


func _create_albedo_placeholder() -> void:
	#1x1 black texture used as a valid binding while the albedo viewport has no
	#render target yet (first frame). The shader skips sampling when albedo_size is 0.
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var view := RDTextureView.new()

	var black_pixel := PackedByteArray()
	black_pixel.resize(4)

	albedo_placeholder = rd.texture_create(format, view, [black_pixel])
	add_rid_to_free(albedo_placeholder, "albedo placeholder texture")


func _build_push_constant(p_render_size: Vector2i) -> PackedFloat32Array:
	push_constant= PackedFloat32Array()
	push_constant.push_back(p_render_size.x)
	push_constant.push_back(p_render_size.y)
	if albedo_handoff and albedo_rd_texture.is_valid():
		#albedo_size is maintained by SSRTAlbedoSource (main thread).
		var albedo_size : Vector2i = albedo_handoff.albedo_size
		push_constant.push_back(albedo_size.x)
		push_constant.push_back(albedo_size.y)
	else:
		push_constant.push_back(0.0)
		push_constant.push_back(0.0)
	return push_constant


func setup_settings() -> void:
	#print("from: SSRT_CE::setup_settings()")
	if not settings.s_changed.is_connected(_settings_changed):
		settings.s_changed.connect(_settings_changed)
		
		
func make_settings_dirty() -> void:
	#print("from: SSRT_CE::make_settings_dirty()")
	settings_dirty = true
	
	
func _recompile_shaders() -> void:
	#print("from: SSRT_CE::_recompile_shaders()")
	trace_shader = create_shader(_shader("trace.glsl"))
	blur_shader = create_shader(_shader("blur.glsl"))
	mix_shader = create_shader(_shader("mix.glsl"))
	mix_ema_shader = create_shader(_shader("mix_ema.glsl"))
	mix_box8_shader = create_shader(_shader("mix_box8.glsl"))
	mix_box16f_shader = create_shader(_shader("mix_box16f.glsl"))
	debug_mv_shader = create_shader(_shader("debug_mv.glsl"))
	debug_albedo_shader = create_shader(_shader("debug_albedo.glsl"))
	shaders_dirty = true
