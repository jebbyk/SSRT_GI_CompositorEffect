@tool
class_name SSRTOffscreenHandoff
extends Resource

## Plain-data bridge between SSRT_CE (allocates the face texture arrays) and
## SSRTOffscreenFaces / SSRTOffscreenFaceCapture (the side renderers).

## RD 2D-array textures (5 layers = face index right,left,up,down,back), owned by
## SSRT_CE. Invalid = capture off / reallocating; the capture effect skips then.
## SSRT_CE nulls these BEFORE freeing (freed RIDs still report is_valid()).
## face_color: rgb = lit color, a = linear depth along the face axis.
## face_normal: the side's native normal_roughness gbuffer, stored raw
##              (decode with normal_roughness_compatibility in the reader).
var face_color_array := RID()
var face_normal_array := RID()

## Side texture size in pixels (non-square: matches the main render aspect). ZERO = unallocated.
var face_size := Vector2i.ZERO
## Main viewport aspect (x/y), published by SSRT_CE render-thread; SSRTOffscreenFaces
## reads it to compute the side yaw/pitch angles from the source camera's fov.
var main_aspect: float = 1.0
## Face yaw/pitch in radians (computed by SSRTOffscreenFaces from the main camera's
## fov so the sides overlap the main screen edge), written main-thread, read by the
## CE's trace push. Order: yaw for right/left faces, pitch for up/down faces.
var face_yaw: float = PI / 2.0
var face_pitch: float = PI / 2.0

## Side viewport render dispatches since launch, index = face. Written by
## SSRTOffscreenFaceCapture, read by SSRT_CE (source-wired warning).
var render_counts := PackedInt32Array([0, 0, 0, 0, 0])

## Debug-only: per-face center-texel linear depth in meters, filled by
## SSRT_CE.debug_read_face_depth_center (render thread).
var debug_depth_readback: Array = []

## Debug-only: per-face center-texel RGB, same fill as debug_depth_readback.
var debug_color_readback: Array = []


## Sum of all per-face dispatch counts (PackedInt32Array has no max() in this engine).
func total_renders() -> int:
	var total := 0
	for c in render_counts:
		total += c
	return total
