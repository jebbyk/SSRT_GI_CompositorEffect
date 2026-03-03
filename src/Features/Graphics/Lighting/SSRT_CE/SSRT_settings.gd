@tool
class_name SSRTSettings
extends Resource

signal s_changed

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
		
@export var sky_color: Color = Color.DEEP_SKY_BLUE:
	set(value):
		if sky_color == value:
			return
		sky_color = value
		s_changed.emit()
		
@export var sky_color_intensity: float:
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
	
