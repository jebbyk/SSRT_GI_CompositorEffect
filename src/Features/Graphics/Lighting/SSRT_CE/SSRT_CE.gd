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

const TRACE_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/trace.glsl"
const BLUR_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/blur.glsl"
const MIX_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/mix.glsl"
const MIX_EMA_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/mix_ema.glsl"
const MIX_BOX8_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/mix_box8.glsl"
const MIX_BOX16F_SHADER_PATH := "res://Features/Graphics/Lighting/SSRT_CE/shaders/mix_box16f.glsl"

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

#Mix pass: set 1 bindings
const ALBEDO_TEXTURE_BINDING := 1
const HISTORY_IMAGE_BINDING := 2
#Ping-pong write partner of the history texture (bound by both EMA and box passes).
const HISTORY_WRITE_BINDING := 3

#Temporal history textures (EMA), created in the shared context, one RGBA16F
#frame each, ping-ponged.
const HISTORY_TEXTURE_NAME: StringName = &"SSRT_History"
const HISTORY_WRITE_TEXTURE_NAME: StringName = &"SSRT_HistoryWrite"

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
var history_image_uniform : RDUniform
var history_write_uniform : RDUniform
var accumulation_weight : float = 1.0

#Box-mode history, per viewport: {vp_key: {"textures": [RID, RID], "swap": int,
#"tex_size": Vector2i}}. Manual RID 3D textures (depth = N, one slice per
#accumulated frame); create_simple_texture is 2D-only. The effect runs on every
#viewport sharing the world and their rasters may differ, so the history is
#keyed per viewport (like the EMA history in the per-viewport
#render_scene_buffers), never shared. With reprojection on there are two
#ping-pong textures: the pass shifts the slots into the new frame's screen
#space each frame and in-place would race across invocations, so the shifted
#copies go to the partner texture which becomes the read texture next frame.
#With reprojection off the second RID is invalid and "swap" stays 0.
var _box_history_by_vp : Dictionary = {}
#Per-viewport frame counter for the rolling box slot (slot = frame % N), keyed by
#the RenderSceneBuffers instance id. First frame: valid_count = 1 -> itself only.
var _box_frame_by_vp : Dictionary = {}
#Last size _render_size_changed acted on, per viewport. The render_size property
#is shared and flips between viewport sizes whenever several viewports run this
#effect, which would retrigger the handler every frame without this dedupe.
var _size_handled_by_vp : Dictionary = {}
var box_slot_index : float = 0.0
var box_valid_count : float = 1.0

#Per-viewport flag that the EMA history has been written at least once, keyed by
#the RenderSceneBuffers instance id (stable per viewport). First frame reads no
#history so uninitialized memory never leaks into the result.
var _ema_valid_by_vp : Dictionary = {}
#Per-viewport EMA ping-pong split (0: read SSRT_History, 1: read
#SSRT_HistoryWrite); flipped after each mix dispatch.
var _ema_swap_by_vp : Dictionary = {}

#Prints once per settings/size change while a box mode falls back to the plain
#mix pass because the 3D history texture could not be created.
var _box_mode_warned : bool = false

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
	#Publish this viewport's raster to the handoff so SSRTAlbedoSource can size
	#its render target to the exact raster the mix pass samples (in the editor
	#the host SubViewport's `size` property does not reflect the 3D panel's
	#render size). Written render-thread / read main-thread, see albedo_handoff.gd.
	#The albedo SubViewport shares this world (variant B), so the compositor
	#invokes this effect there too; its passes are then auto-skipped by
	#run_compute_shader() (its depth layer lacks TEXTURE_USAGE_STORAGE_BIT).
	#Both viewports render at the same raster, so the value is stable.
	if albedo_handoff:
		albedo_handoff.render_size = render_size
	
	if not settings_ubo.is_valid() or settings_dirty or shaders_dirty:
		#print("from: SSRT_CE::_render_setup(). msg: Settings are dirty")
		create_settings_uniform_buffer()
		create_trace_pipeline()
		create_blur_pipelines()
		create_mix_pipeline()
		create_mix_ema_pipeline()
		create_mix_box8_pipeline()
		create_mix_box16f_pipeline()
		shaders_dirty = false
		_report_vram_estimate()
	
	_resolve_albedo_texture()
	
	if not render_scene_buffers.has_texture(context, texture_a):
		create_textures()
	
	#2/(N+1): classic EMA-to-SMA match, so the slider reads as a "~N-frame average"
	#(mean lag (N-1)/2 frames). N=1 -> weight 1.0 -> identical to no accumulation.
	accumulation_weight = 2.0 / float(settings.accumulation_frames + 1)
	
	if _ema_active():
		var vp_key : int = render_scene_buffers.get_instance_id()
		if not render_scene_buffers.has_texture(context, HISTORY_TEXTURE_NAME) \
		   or not render_scene_buffers.has_texture(context, HISTORY_WRITE_TEXTURE_NAME):
			_create_history_texture()
			#Fresh ping-pong pair: define the first read/write split.
			_ema_swap_by_vp[vp_key] = 0
		else:
			#Rebind every frame: after a box->EMA switch the uniforms may still
			#hold the (freed) box history RIDs, and the split flips after each
			#mix dispatch.
			_rebind_ema_uniforms(vp_key)
	elif _box_wanted():
		_ensure_box_history()
		
	push_constant = _build_push_constant(render_size)#TODO no need to do it every frame?
		
		
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


func _ema_active() -> bool:
	return settings.accumulation_mode == SSRTSettings.AccumulationMode.EMA


func _create_history_texture() -> void:
	#Two ping-pong RGBA16F frames, sampleable (reprojection reads the other
	#slot at an offset UV). Live in the render_scene_buffers context: freed on
	#clear_context (mode / frames / size change) and recreated here. Created
	#per name so a context holding only one of the pair completes in place.
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


func _rebind_ema_uniforms(p_vp_key: int) -> void:
	#Ping-pong split: one texture is read (history), the other written
	#(history_write), flipped after each mix dispatch.
	var read_name : StringName = HISTORY_TEXTURE_NAME
	var write_name : StringName = HISTORY_WRITE_TEXTURE_NAME
	if _ema_swap_by_vp.get(p_vp_key, 0) == 1:
		read_name = HISTORY_WRITE_TEXTURE_NAME
		write_name = HISTORY_TEXTURE_NAME
	history_image_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, read_name, 0, 0, 1, 1),
		HISTORY_IMAGE_BINDING
	)
	history_write_uniform = get_image_uniform(
		render_scene_buffers.get_texture_slice(context, write_name, 0, 0, 1, 1),
		HISTORY_WRITE_BINDING
	)


func _box_wanted() -> bool:
	var mode := settings.accumulation_mode
	return mode == SSRTSettings.AccumulationMode.BOX8 or mode == SSRTSettings.AccumulationMode.BOX16F


func _reprojection_enabled() -> float:
	return 1.0 if settings.reprojection_enabled else 0.0


func _ensure_box_history() -> void:
	#This viewport's N-frame 3D history (depth = N), rolling slot = frame % N.
	#Deferred until the viewport has a real raster; a failed create leaves no
	#entry and the mix pass falls back to the plain mix pass.
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
	var textures : Array = []
	for i in count:
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM \
			if settings.accumulation_mode == SSRTSettings.AccumulationMode.BOX8 \
			else RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = render_size.x
		format.height = render_size.y
		#The 3D extent comes from `depth` for TEXTURE_TYPE_3D (drivers force
		#array_layers to 1 there); N slices live in the depth dimension.
		format.depth = settings.accumulation_frames
		format.array_layers = 1
		format.mipmaps = 1
		format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT

		var view := RDTextureView.new()
		var texture : RID = rd.texture_create(format, view, [])
		if not texture.is_valid():
			#What was created so far stays tracked in _rids_to_free (predelete
			#frees it); without an entry the mix pass falls back to plain mix.
			push_error("from: SSRT_CE::_ensure_box_history(). msg: 3D history texture creation failed (%dx%dxN, N=%d, texture %d of %d)." % [
				render_size.x,
				render_size.y,
				settings.accumulation_frames,
				i + 1, count,
			])
			return
		add_rid_to_free(texture, "box history texture")
		textures.append(texture)
	while textures.size() < 2:
		textures.append(RID())
	_box_history_by_vp[vp_key] = {"textures": textures, "swap": 0, "tex_size": render_size}
	_rebind_box_uniforms(_box_history_by_vp[vp_key])


func _rebind_box_uniforms(p_entry: Variant) -> void:
	var t0 : RID = p_entry.textures[0]
	var t1 : RID = p_entry.textures[1]
	var read : RID = t0
	var write : RID = t0
	if t1.is_valid():
		read = t0 if p_entry.swap == 0 else t1
		write = t1 if p_entry.swap == 0 else t0
	history_image_uniform = get_image_uniform(read, HISTORY_IMAGE_BINDING)
	history_write_uniform = get_image_uniform(write, HISTORY_WRITE_BINDING)


func _drop_box_history_entry(p_vp_key: int) -> void:
	var entry : Variant = _box_history_by_vp.get(p_vp_key)
	if entry == null:
		return
	_box_history_by_vp.erase(p_vp_key)
	for texture in entry.textures:
		if texture.is_valid():
			#free_rid is render-thread-only, while settings/size changes and
			#predelete arrive on the main thread; a skipped free leaks the
			#texture and later allocations can fail. Erased from _rids_to_free
			#first so predelete does not free it again.
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
	#Informational: history footprint so a large mode/frame-count choice is a
	#conscious decision, not an OOM surprise. EMA keeps one ping-pong pair.
	var w : int = render_size.x
	var h : int = render_size.y
	var frames : int = settings.accumulation_frames if not _ema_active() else 1
	var copies : int = 2 if _ema_active() or (_box_wanted() and settings.reprojection_enabled) else 1
	var bytes : int = w * h * frames * settings.bytes_per_pixel() * copies
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
		#EMA temporal accumulation: bind the history image (set 1, binding 2)
		#and its ping-pong write partner (binding 3).
		mix_uniforms.append(history_image_uniform)
		mix_uniforms.append(history_write_uniform)
		var vp_key : int = render_scene_buffers.get_instance_id()
		var history_valid : float = 1.0 if _ema_valid_by_vp.get(vp_key, false) else 0.0
		#The mix_ema push constant extends the base 16-byte one with weight/valid
		#/reprojection, to 28 bytes — must match the shader's declared size exactly
		#(no padding).
		var ema_push : PackedFloat32Array = push_constant.duplicate()
		ema_push.push_back(accumulation_weight)
		ema_push.push_back(history_valid)
		ema_push.push_back(_reprojection_enabled())
		uniform_sets = [
			scene_uniform_set,
			mix_uniforms
		]
		run_compute_shader(
			"SSRT: mix (EMA)",
			mix_ema_shader,
			mix_ema_pipeline,
			uniform_sets,
			ema_push,
		)
		#The albedo SubViewport auto-skips this pass, so flagging it valid and
		#flipping the split are harmless there: it never touches the history.
		_ema_valid_by_vp[vp_key] = true
		_ema_swap_by_vp[vp_key] = 1 - _ema_swap_by_vp.get(vp_key, 0)
	elif _box_wanted() and _box_history_by_vp.has(render_scene_buffers.get_instance_id()):
		#Flat N-frame average: the shader writes the current frame to the rolling
		#slot and averages the last min(frame+1, N) slots. The albedo SubViewport
		#auto-skips this pass, so advancing its counter is harmless (it never
		#writes the shared history).
		var is_box8 : bool = settings.accumulation_mode == SSRTSettings.AccumulationMode.BOX8
		var box_shader : RID = mix_box8_shader if is_box8 else mix_box16f_shader
		var box_pipeline : RID = mix_box8_pipeline if is_box8 else mix_box16f_pipeline
		mix_uniforms.append(history_image_uniform)
		mix_uniforms.append(history_write_uniform)
		var vp_key : int = render_scene_buffers.get_instance_id()
		var frame : int = _box_frame_by_vp.get(vp_key, -1) + 1
		var n : int = settings.accumulation_frames
		box_slot_index = float(frame % n)
		box_valid_count = float(mini(frame + 1, n))
		_box_frame_by_vp[vp_key] = frame
		#Like the EMA pass: extend the base 16-byte push constant to 28 bytes
		#(slot + valid_count + reprojection), matching the shader's declared size
		#exactly.
		var box_push : PackedFloat32Array = push_constant.duplicate()
		box_push.push_back(box_slot_index)
		box_push.push_back(box_valid_count)
		box_push.push_back(_reprojection_enabled())
		uniform_sets = [
			scene_uniform_set,
			mix_uniforms
		]
		run_compute_shader(
			"SSRT: mix (BOX8)" if is_box8 else "SSRT: mix (BOX16F)",
			box_shader,
			box_pipeline,
			uniform_sets,
			box_push,
		)
		#Advance the ping-pong swap. Harmless on a viewport whose pass is
		#memoized-skipped (the albedo SubViewport): its textures are then never
		#read or written, so the index is meaningless there.
		var entry : Variant = _box_history_by_vp.get(vp_key)
		if entry.textures[1].is_valid():
			entry.swap = 1 - entry.swap
	else:
		#Defensive: a box mode without a valid 3D history texture composites the
		#per-frame estimate.
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
	#The shared render_size property flips between viewport sizes on every
	#viewport callback; act only when this viewport's size really changed.
	if _size_handled_by_vp.get(vp_key) == render_size:
		return
	_size_handled_by_vp[vp_key] = render_size
	render_scene_buffers.clear_context(context)
	#clear_context frees this viewport's EMA history; drop its box history and
	#rolling counter so the recreated history is not read before its first
	#frame writes it. Other viewports keep accumulating.
	_ema_valid_by_vp.erase(vp_key)
	_ema_swap_by_vp.erase(vp_key)
	_box_frame_by_vp.erase(vp_key)
	_drop_box_history_entry(vp_key)
	_box_mode_warned = false
	make_settings_dirty()
	
	
func _settings_changed() -> void:
	#print("from: SSRT_CE::_settings_changed()")
	#Runs on the main thread (inspector): touch no RIDs directly.
	#Deliberately no clear_context here: the context textures are size-bound,
	#and a main-thread clear both fails to free them (render-thread-only) and
	#leaks them. Stale EMA/box contents are made harmless by the per-viewport
	#validity flags reset below; size changes clear via _render_size_changed
	#(render thread, where frees work).
	_ema_valid_by_vp.clear()
	_ema_swap_by_vp.clear()
	_box_frame_by_vp.clear()
	_box_mode_warned = false
	_free_box_history()
	make_settings_dirty()


func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		#The deferred frees are static RID-only callables, safe after self is
		#gone; the base predelete then frees the rest of _rids_to_free.
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
	trace_shader = create_shader(TRACE_SHADER_PATH)
	blur_shader = create_shader(BLUR_SHADER_PATH)
	mix_shader = create_shader(MIX_SHADER_PATH)
	mix_ema_shader = create_shader(MIX_EMA_SHADER_PATH)
	mix_box8_shader = create_shader(MIX_BOX8_SHADER_PATH)
	mix_box16f_shader = create_shader(MIX_BOX16F_SHADER_PATH)
	shaders_dirty = true
