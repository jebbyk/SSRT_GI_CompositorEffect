@tool
class_name SSRTAlbedoHandoff
extends Resource

## Plain-data bridge between SSRTAlbedoSource (main thread) and SSRT_CE (render thread).

var viewport_rid: RID
var albedo_size := Vector2i.ZERO
var render_size := Vector2i.ZERO
## Environment.fog_mode of the camera the source mirrors (-1 = not resolved yet).
## Written main-thread, read render-thread — same contract as albedo_size.
var fog_mode: int = -1
