@tool
class_name SSRTOffscreenHandoff
extends Resource

## Plain-data bridge between SSRT_CE (allocates the face texture arrays) and
## SSRTOffscreenFaceCapture (fills them inside the side viewports).
## All fields are written and read on the render thread.

## RD 2D-array textures (5 layers = face index), owned by SSRT_CE.
## Invalid = capture off or arrays being reallocated; the capture effect skips then.
## SSRT_CE nulls these BEFORE freeing, because freed RIDs still report is_valid().
var face_color_array := RID()
var face_depth_array := RID()

## Side texture edge in pixels; 0 = arrays not allocated.
var face_size_px: int = 0

## Side viewport render dispatches since launch, index = face (right, left, up, down,
## back). Written by SSRTOffscreenFaceCapture, read by SSRT_CE (source-wired warning).
var render_counts := PackedInt32Array([0, 0, 0, 0, 0])

## Debug-only: per-face center-texel linear depth in meters, filled by
## SSRT_CE.debug_read_face_depth_center (render thread).
var debug_depth_readback: Array = []


## Sum of all per-face dispatch counts (PackedInt32Array has no max() in this engine).
func total_renders() -> int:
	var total := 0
	for c in render_counts:
		total += c
	return total
