@tool
class_name SSRTSettings
extends Resource

signal s_changed

@export_category("Trace settings")
@export_range(1, 1024, 1) var rays_amount: int = 4:
	set(value):
		if rays_amount == value:
			return
		rays_amount = value
		s_changed.emit()
		
		
@export_range(1, 512, 1) var steps_per_ray: int = 32:
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


@export_range(0.0, 100.0, 0.01) var bounce_intensity: float = 1.0:
	set(value):
		if bounce_intensity == value:
			return
		bounce_intensity = value
		s_changed.emit()
		
		
@export_range(0.0, 100.0, 0.01) var occlusion_intensity: float = 1.0:
	set(value):
		if occlusion_intensity == value:
			return
		occlusion_intensity = value
		s_changed.emit()
		
		
@export var back_face_lighting: bool = false:
	set(value):
		if back_face_lighting == value:
			return
		back_face_lighting = value
		s_changed.emit()
		
		
@export var z_thickness: float = 0.5:
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

@export_range(0.0, 1.0, 0.001) var blur_plane_treshold: float = 0.5:
	set(value):
		if blur_plane_treshold == value:
			return
		blur_plane_treshold = value
		s_changed.emit()


@export_category("Temporal settings")
enum AccumulationMode { EMA, BOX8, BOX16F }

## Temporal accumulation mode. EMA: exponential, one frame of history, window
## of ~N frames (mean lag (N-1)/2). BOX8: exact flat average of the last N
## frames in RGBA8 (RGB stored * 1/256, ~1.0 precision after decode, cheapest
## VRAM). BOX16F: the same exact N-frame average at full RGBA16F precision
## (most VRAM). (Plain @export takes no tooltip argument in Godot 4.7, so this
## note is doc-only, not an inspector tooltip.)
@export var accumulation_mode: AccumulationMode = AccumulationMode.EMA:
	set(value):
		if accumulation_mode == value:
			return
		accumulation_mode = value
		s_changed.emit()


## Temporal window in frames. EMA: weight = 2/(N+1), the classic match to a
## flat ~N-frame average (mean lag (N-1)/2). BOX8 / BOX16F: exact flat average
## of the last N frames (history depth = N). 1 = accumulation off.
@export_range(1, 256, 1, "Temporal window (frames): EMA ≈ flat average of ~N frames (mean lag (N-1)/2); BOX8/BOX16F = exact flat average of the last N frames (history = N frames of VRAM). Higher = smoother but more ghosting. 1 = off.") var accumulation_frames: int = 1:
	set(value):
		if accumulation_frames == value:
			return
		accumulation_frames = value
		s_changed.emit()


## Bytes per pixel of the temporal history, for the VRAM estimate readout.
## BOX8 stores 4 bytes/px (RGBA8); EMA and BOX16F store 8 bytes/px (RGBA16F).
func bytes_per_pixel() -> int:
	if accumulation_mode == AccumulationMode.BOX8:
		return 4
	return 8
