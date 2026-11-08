class_name FreeLookCamera extends Camera3D

# Modifier keys' speed multiplier
const SHIFT_MULTIPLIER = 2.5
const ALT_MULTIPLIER = 1.0 / SHIFT_MULTIPLIER

# Editor-style orbit (LMB drag) / dolly (wheel)
const ORBIT_INITIAL_DISTANCE = 8.0
const ORBIT_MIN_DISTANCE = 0.5
const ORBIT_MAX_DISTANCE = 100.0

@export_range(0.0, 1.0) var sensitivity: float = 0.25
@export_range(0.01, 2.0) var orbit_sensitivity: float = 0.2
## Per-notch wheel zoom multiplier, applied to the target distance (eased by dolly_speed)
@export_range(1.01, 2.0, 0.01) var orbit_zoom_factor: float = 1.1
## Exponential easing rate (1/s) for the wheel dolly
@export_range(2.0, 30.0) var dolly_speed: float = 12.0

# Mouse state
var _mouse_position = Vector2(0.0, 0.0)
var _total_pitch = 0.0

# Orbit state: camera position = pivot + distance * dir(yaw, pitch)
var _orbit_pivot = Vector3.ZERO
var _orbit_yaw = 0.0
var _orbit_pitch = 0.0
var _orbit_distance = ORBIT_INITIAL_DISTANCE
var _dolly_target = ORBIT_INITIAL_DISTANCE
var _orbiting = false
var _orbit_initialized = false

# Movement state
var _direction = Vector3(0.0, 0.0, 0.0)
var _velocity = Vector3(0.0, 0.0, 0.0)
var _acceleration = 30
var _deceleration = -10
var _vel_multiplier = 4

# Keyboard state
var _w = false
var _s = false
var _a = false
var _d = false
var _q = false
var _e = false
var _shift = false
var _alt = false

func _input(event):
	# Receives mouse motion
	if event is InputEventMouseMotion:
		_mouse_position = event.relative
		# Orbit (LMB or MMB drag), skipped while RMB mouselook is captured
		if _orbiting and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			_orbit_yaw -= deg_to_rad(event.relative.x * orbit_sensitivity)
			_orbit_pitch = clamp(_orbit_pitch + deg_to_rad(event.relative.y * orbit_sensitivity), deg_to_rad(-89.9), deg_to_rad(89.9))
			_apply_orbit()
	
	# Receives mouse button input
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE: # Orbit; wheel-press orbits too (Blender-style)
				_orbiting = event.pressed
				if event.pressed:
					_reanchor_orbit()
			MOUSE_BUTTON_RIGHT: # Only allows rotation if right click down
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE)
			MOUSE_BUTTON_WHEEL_UP: # Dolly in
				_start_dolly(1.0 / orbit_zoom_factor)
			MOUSE_BUTTON_WHEEL_DOWN: # Dolly out
				_start_dolly(orbit_zoom_factor)

	# Receives key input
	if event is InputEventKey:
		match event.keycode:
			KEY_W:
				_w = event.pressed
			KEY_S:
				_s = event.pressed
			KEY_A:
				_a = event.pressed
			KEY_D:
				_d = event.pressed
			KEY_Q:
				_q = event.pressed
			KEY_E:
				_e = event.pressed
			KEY_SHIFT:
				_shift = event.pressed
			KEY_ALT:
				_alt = event.pressed

# Updates mouselook, movement and dolly easing every frame
func _process(delta):
	_update_mouselook()
	_update_movement(delta)
	_update_dolly(delta)

# Updates camera movement
func _update_movement(delta):
	# Orbit owns the camera while LMB/MMB are down, else WASD would fight it
	if _orbiting:
		return
	# Computes desired direction from key states
	_direction = Vector3(
		(_d as float) - (_a as float), 
		(_e as float) - (_q as float),
		(_s as float) - (_w as float)
	)
	
	# Computes the change in velocity due to desired direction and "drag"
	# The "drag" is a constant acceleration on the camera to bring it's velocity to 0
	var offset = _direction.normalized() * _acceleration * _vel_multiplier * delta \
		+ _velocity.normalized() * _deceleration * _vel_multiplier * delta
	
	# Compute modifiers' speed multiplier
	var speed_multi = 1
	if _shift: speed_multi *= SHIFT_MULTIPLIER
	if _alt: speed_multi *= ALT_MULTIPLIER
	
	# Checks if we should bother translating the camera
	if _direction == Vector3.ZERO and offset.length_squared() > _velocity.length_squared():
		# Sets the velocity to 0 to prevent jittering due to imperfect deceleration
		_velocity = Vector3.ZERO
	else:
		# Clamps speed to stay within maximum value (_vel_multiplier)
		_velocity.x = clamp(_velocity.x + offset.x, -_vel_multiplier, _vel_multiplier)
		_velocity.y = clamp(_velocity.y + offset.y, -_vel_multiplier, _vel_multiplier)
		_velocity.z = clamp(_velocity.z + offset.z, -_vel_multiplier, _vel_multiplier)
	
		translate(_velocity * delta * speed_multi)

# Updates mouse look 
func _update_mouselook():
	# Only rotates mouse if the mouse is captured
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_mouse_position *= sensitivity
		var yaw = _mouse_position.x
		var pitch = _mouse_position.y
		_mouse_position = Vector2(0, 0)
		
		# Prevents looking up/down too far
		pitch = clamp(pitch, -90 - _total_pitch, 90 - _total_pitch)
		_total_pitch += pitch
	
		rotate_y(deg_to_rad(-yaw))
		rotate_object_local(Vector3(1,0,0), deg_to_rad(-pitch))

# Re-derives the orbit state from the current pose (preserving the distance), so
# orbit/zoom right after a free-look rotation starts from the current view, not a stale one.
func _reanchor_orbit():
	# basis.z is the pivot->camera axis once the pivot sits `distance` along the view direction
	var to_camera := global_transform.basis.z
	_orbit_pivot = global_position - to_camera * _orbit_distance
	_orbit_yaw = atan2(to_camera.x, to_camera.z)
	_orbit_pitch = asin(clamp(to_camera.y, -1.0, 1.0))
	_orbit_initialized = true

# Wheel notches stack on the target; _update_dolly eases the distance toward it.
func _start_dolly(factor: float):
	_reanchor_orbit()
	_dolly_target = clamp(_dolly_target * factor, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE)

func _update_dolly(delta: float):
	if absf(_orbit_distance - _dolly_target) < 0.001:
		return
	_orbit_distance = lerpf(_orbit_distance, _dolly_target, 1.0 - exp(-dolly_speed * delta))
	if absf(_orbit_distance - _dolly_target) < 0.001:
		_orbit_distance = _dolly_target
	_apply_orbit()

func _apply_orbit():
	if not _orbit_initialized:
		return
	var dir := Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)
	)
	global_position = _orbit_pivot + dir * _orbit_distance
	look_at(_orbit_pivot, Vector3.UP)
