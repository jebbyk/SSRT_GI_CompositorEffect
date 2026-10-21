@tool
class_name SSRTAlbedoHandoff
extends Resource

## Plain-data bridge between SSRTAlbedoSource (main thread) and SSRT_CE (render thread).

var viewport_rid: RID
var albedo_size := Vector2i.ZERO
var render_size := Vector2i.ZERO
