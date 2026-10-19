## Slowly rotates the node around its local axes.
## Speed is in degrees per second per axis, so rotation is independent of FPS.
## A zero component on an axis leaves that axis untouched.
class_name AxisRotator
extends Node3D

## Rotation speed in degrees/second for each local axis (X, Y, Z).
@export var rotation_speed: Vector3 = Vector3(0.0, 45.0, 0.0)

func _process(delta: float) -> void:
	rotation.x += deg_to_rad(rotation_speed.x) * delta
	rotation.y += deg_to_rad(rotation_speed.y) * delta
	rotation.z += deg_to_rad(rotation_speed.z) * delta
