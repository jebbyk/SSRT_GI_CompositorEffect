class_name SSRTAlbedoHandoff
extends Resource

## Plain-data bridge between SSRTAlbedoSource (main thread) and SSRT_CE (render thread).
##
## SSRTAlbedoSource fills these fields on _ready (viewport RID) and on resize (size).
## SSRT_CE reads them every frame while setting up the mix pass.
##
## Kept as a shared Resource (instead of a Node reference) because Godot 4.7
## does not allow Node-typed @export properties on Resource classes.

var viewport_rid: RID
var albedo_size := Vector2i.ZERO
