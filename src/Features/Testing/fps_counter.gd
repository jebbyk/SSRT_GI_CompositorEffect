## Live FPS / frame-time HUD label. Anchor the node to a screen corner in the editor.
class_name FpsCounter
extends Label

func _process(delta: float) -> void:
	var fps = Engine.get_frames_per_second()
	text = "FPS: %d (%.1f ms)" % [fps, delta * 1000.0]
