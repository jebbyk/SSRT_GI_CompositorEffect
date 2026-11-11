#[compute]
#version 450

layout(constant_id = 0) const bool ALBEDO_GI = false;
//Off for this RGBA16F entry: full float, HDR RGB + AO, no encoding.
layout(constant_id = 1) const bool HISTORY_SCALED = false;

//N-frame RGBA16F history (depth = N): full float, HDR RGB + AO, no encoding.
layout(rgba16f, set = 1, binding = 2) uniform image3D history;
//Ping-pong write partner, used only with reprojection on (slots are shifted there,
//textures swapped after the pass). Reprojection off: both bindings are the same texture.
layout(rgba16f, set = 1, binding = 3) uniform image3D history_write;

//The glsl importer only splices #include one level deep: every include lives in the
//entry, and included files must not #include anything themselves.
#include "includes/scene_data.glsl"
#include "includes/reprojection.glsl"
#include "includes/mix_box_decl.glsl"
#include "includes/common.glsl"
#include "includes/albedo.glsl"
#include "includes/fog.glsl"
#include "includes/disocclusion.glsl"
#include "includes/mix_box_main.glsl"
