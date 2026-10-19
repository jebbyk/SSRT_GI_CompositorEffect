@tool
class_name SSRTAlbedoHandoff
extends Resource

## Plain-data bridge between SSRTAlbedoSource (main thread) and SSRT_CE (render thread).
##
## SSRTAlbedoSource fills viewport_rid on _ready and albedo_size on resize.
## SSRT_CE fills render_size every frame (the raster of the viewport it runs in)
## and reads the rest while setting up the mix pass. The albedo SubViewport
## shares this world, so the compositor invokes the CE there too, but its
## passes are auto-skipped (its depth layer lacks TEXTURE_USAGE_STORAGE_BIT);
## only the main viewport's passes run, and both render at the same raster.
## Cross-thread single-field writes/reads with a 1-frame lag: the mix pass
## scales UVs by albedo_size, so a briefly stale size is harmless.
##
## @tool is required: in the editor non-tool scripts get a placeholder instance
## without live variables (EditorNode disables scripting for non-tool scripts),
## which would make every viewport_rid/albedo_size access a script error and
## silently disable the albedo path in the 3D preview (SSRT_CE would fall back
## to the legacy lit-color modulation).
##
## Kept as a shared Resource (instead of a Node reference) because Godot 4.7
## does not allow Node-typed @export properties on Resource classes.

var viewport_rid: RID
var albedo_size := Vector2i.ZERO
## Raster size of the viewport the CE runs in. Written by SSRT_CE every frame
## (render thread); read by SSRTAlbedoSource to size its render target to the
## exact raster the mix pass samples.
var render_size := Vector2i.ZERO
