#[compute]
#version 450

layout(constant_id = 0) const bool ALBEDO_GI = false;
//On for this RGBA8 entry: the shared body encodes history RGB *1/8 and decodes *8.
layout(constant_id = 1) const bool HISTORY_SCALED = true;

//N-frame RGBA8 history. RGB stored *1/8 (trace output lives in ~0..8; the 8-bit step
//~0.031 is below per-frame ray noise). Above 8 clips. AO in 0..1 as-is.
layout(rgba8, set = 1, binding = 2) uniform image3D history;
//Ping-pong write partner, used only with reprojection on (slots are shifted there,
//textures swapped after the pass). Reprojection off: both bindings are the same texture.
layout(rgba8, set = 1, binding = 3) uniform image3D history_write;

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
