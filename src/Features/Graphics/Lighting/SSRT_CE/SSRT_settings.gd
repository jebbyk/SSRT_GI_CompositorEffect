@tool
class_name SSRTSettings
extends Resource

signal s_changed

@export_category("Trace settings")
@export_range(1, 1024, 1) var rays_amount: int = 8:
	set(value):
		if rays_amount == value:
			return
		rays_amount = value
		s_changed.emit()
		
		
@export_range(1, 512, 1) var steps_per_ray: int = 64:
	set(value):
		if steps_per_ray == value:
			return
		steps_per_ray = value
		s_changed.emit()
	
		
@export_range(0.0, 20.0, 0.1) var ray_length: float = 1.0:
	set(value):
		if ray_length == value:
			return
		ray_length = value
		s_changed.emit()
		
		
@export var depth_affect_ray_length: bool = true:
	set(value):
		if depth_affect_ray_length == value:
			return
		depth_affect_ray_length = value
		s_changed.emit()


@export_range(0.0, 100.0, 0.01) var bounce_intensity: float = 0.5:
	set(value):
		if bounce_intensity == value:
			return
		bounce_intensity = value
		s_changed.emit()
		
		
@export_range(0.0, 100.0, 0.01) var occlusion_intensity: float = 5.0:
	set(value):
		if occlusion_intensity == value:
			return
		occlusion_intensity = value
		s_changed.emit()
		
		
@export var back_face_lighting: bool = true:
	set(value):
		if back_face_lighting == value:
			return
		back_face_lighting = value
		s_changed.emit()
		
		
## Probe acceptance window in ray step lengths (step-relative, not absolute world units).
@export var z_thickness: float = 10.0:
	set(value):
		if z_thickness == value:
			return
		z_thickness = value
		s_changed.emit()
		

@export_range(0.0, 1.0, 0.001) var normal_treshold: float = 0.5:
	set(value):
		if normal_treshold == value:
			return
		normal_treshold = value
		s_changed.emit()
		
		
@export var sky_color: Color = Color.DEEP_SKY_BLUE:
	set(value):
		if sky_color == value:
			return
		sky_color = value
		s_changed.emit()
		
		
@export_range(0.0, 100.0, 0.01) var sky_color_intensity: float:
	set(value):
		if sky_color_intensity == value:
			return
		sky_color_intensity = value
		s_changed.emit()
		
		
@export var far_plane: float = 1000.0:
	set(value):
		if far_plane == value:
			return
		far_plane = value
		s_changed.emit()
	
	
@export_category("Denoise settings")
@export_range(1, 10, 1) var blur_kernel_size: int = 2:
	set(value):
		if blur_kernel_size == value:
			return
		blur_kernel_size = value
		s_changed.emit()
		
@export_range(0, 4, 1) var blur_steps: int = 1:
	set(value):
		if blur_steps == value:
			return
		blur_steps = value
		s_changed.emit()

@export_range(0.0, 1.0, 0.001) var blur_normal_treshold: float = 0.5:
	set(value):
		if blur_normal_treshold == value:
			return
		blur_normal_treshold = value
		s_changed.emit()

@export_range(0.0, 1.0, 0.001) var blur_plane_treshold: float = 0.35:
	set(value):
		if blur_plane_treshold == value:
			return
		blur_plane_treshold = value
		s_changed.emit()


@export_category("Temporal settings")
enum AccumulationMode { EMA, BOX8, BOX16F }

## Accumulation mode. EMA: exponential, ~N-frame window. BOX8: exact flat N-frame
## average in RGBA8 (RGB stored *1/8, clips above 8, cheapest VRAM). BOX16F: the same,
## full RGBA16F precision (most VRAM).
@export var accumulation_mode: AccumulationMode = AccumulationMode.EMA:
	set(value):
		if accumulation_mode == value:
			return
		accumulation_mode = value
		s_changed.emit()


## Temporal window (frames). EMA: weight = 1 - 0.05^(1/N) (~5% of the old value remains after N frames).
## BOX: exact flat average of the last N frames. 1 = off.
@export_range(1, 64, 1, "Temporal window (frames): EMA weight = 1 - 0.05^(1/N) (~95% response after N frames); BOX8/BOX16F = exact flat average of the last N frames (history = N frames of VRAM). Higher = smoother but more ghosting. 1 = off.") var accumulation_frames: int = 64:
	set(value):
		#Clamp to the current max (saved values may predate it).
		value = clampi(value, 1, 64)
		if accumulation_frames == value:
			return
		accumulation_frames = value
		s_changed.emit()


## Reproject the history read to the pixel's previous-frame position. Off = read at the same pixel (ghosts under camera motion).
@export var reprojection_enabled: bool = true:
	set(value):
		if reprojection_enabled == value:
			return
		reprojection_enabled = value
		s_changed.emit()


## Disocclusion revalidation: reject stored history whose surface depth differs from the
## current depth by more than this relative amount. 0 = disabled. Higher = more ghosting,
## lower = more resets/shimmer.
@export_range(0.0, 0.5, 0.001) var reproj_depth_threshold: float = 0.05:
	set(value):
		if reproj_depth_threshold == value:
			return
		reproj_depth_threshold = value
		s_changed.emit()


## Filter the history read at the fractional reprojection position (4-tap bilinear).
## Off = nearest texel: crisper, but sub-texel motion quantizes to 0/1-texel jumps.
@export var bilinear_reprojection: bool = true:
	set(value):
		if bilinear_reprojection == value:
			return
		bilinear_reprojection = value
		s_changed.emit()


@export_category("Debug")
enum DebugView { NONE, MOTION_VECTORS, UNLIT_ALBEDO }

## Debug overlay replacing the effect output. MOTION_VECTORS: black = static, R/G = x/y motion
## (64 px = full range), red = previous position off-screen. UNLIT_ALBEDO: the unlit albedo the
## GI bounce modulates by (lit-color fallback where no source viewport is wired up). Skips trace/blur/mix.
@export var debug_view: DebugView = DebugView.NONE:
	set(value):
		if debug_view == value:
			return
		debug_view = value
		s_changed.emit()


## History bytes/pixel for the VRAM estimate: BOX8 = 4 (RGBA8), EMA/BOX16F = 8 (RGBA16F).
func bytes_per_pixel() -> int:
	if accumulation_mode == AccumulationMode.BOX8:
		return 4
	return 8
