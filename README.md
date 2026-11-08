# SSRT_GI_CompositorEffect
Screen Space Global Illumination Compositor Effect for Godot projects

<img width="720" height="405" alt="p1_00m00-00m38" src="https://github.com/user-attachments/assets/a1df6074-9996-4e1b-acd2-cd6e0f68caab" />

<img width="720" height="405" alt="p2_00m41-00m53" src="https://github.com/user-attachments/assets/a4900d89-2a12-461f-b97c-f6d709f0fccd" />

<img width="720" height="405" alt="p3_01m00-01m17" src="https://github.com/user-attachments/assets/2b521203-f65f-4127-aa0d-3f9ba6ad9ecb" />

<img width="720" height="405" alt="p4_01m22-01m52" src="https://github.com/user-attachments/assets/349ba2e6-5c32-41c1-9c84-7cc51cfd37ca" />

<img width="720" height="405" alt="p6_02m15-02m36" src="https://github.com/user-attachments/assets/0a686e76-fdbb-4cf9-b493-9f7c4a97f087" />

## Integrating SSRT_CE into a Godot project

Tested with Godot 4.7.x, Forward+ renderer. A working reference setup lives in this repo on the `lumberyard-demo` branch (`src/demo/lumberyard_demo.tscn`).

### 1. Copy the effect folder

Copy `Features/Graphics/Lighting/SSRT_CE/` (GDScript + `.uid` files + `shaders/` with `.import` files) into your project **keeping the exact path** `res://Features/Graphics/Lighting/SSRT_CE/`. The shader locations are hardcoded constants inside `SSRT_CE.gd`, so moving the folder requires editing those paths.

### 2. Project settings

- Enable MSAA on the main viewport (`rendering/anti_aliasing/quality/msaa_3d` = 2x or more). The effect needs the MSAA depth layer (R32 + STORAGE_BIT) to build its scene uniform set; on a MSAA-less viewport it logs a warning once and skips its passes there.
- If your scene's lights use physical units (lumens/lux), enable `rendering/lights_and_shadows/use_physical_light_units`.

### 3. Wire the effect in a scene

Three pieces, all attachable in the editor:

1. **Compositor + CompositorEffect** on the scene's `WorldEnvironment` (or on a `Camera3D.compositor` to scope it to one camera):
   - add a `Compositor`, then a `CompositorEffect` with `script = SSRT_CE.gd`, `effect_callback_type = Custom`, `enabled = true`.
   - `access_resolved_color`, `access_resolved_depth`, `needs_motion_vectors`, `needs_normal_roughness`, `needs_separate_specular` are all set automatically by the script on resource init (leave them as the script sets them).
2. **Settings resource**: add a `Resource` with `script = SSRT_settings.gd` to the effect's `settings` property. All trace/denoise/temporal/debug parameters are `@export`ed there (inspector-editable, live-updating). Leave it default for a first run.
3. **Albedo source viewport**: add a `SubViewport` with `script = albedo_source_viewport.gd` (class `SSRTAlbedoSource`) and set its `camera_source` to your main camera. This renders an unshaded (UNSHADOWED) copy of the scene from the same camera; the GI bounce is modulated by that unlit albedo instead of the already-lit scene color.

Share **one** `Resource` with `script = albedo_handoff.gd` between the effect's `albedo_handoff` and the SubViewport's `albedo_handoff` — that's the bridge (the SubViewport publishes its render target, the effect samples it).

In the editor this is: create the handoff/settings as sub-resources inside the scene, or as external `.tres` files and drag them into both properties. The demo scene does it with sub-resources.

### 4. Camera requirements

- One main camera (`current = true`) whose transform you control. The albedo SubViewport mirrors its transform/fov/clip every frame, so it must see the same view as the game camera.
- The SubViewport manages its own size (it tracks the main viewport's render size), update mode, and debug draw — don't override those.
- If you use additional SubViewports that render the same world, know that compositor effects are **world-scoped**: they run in every such viewport. To exclude a viewport, assign an empty `Compositor` to its camera (the albedo source SubViewport does this to itself automatically). Viewports without MSAA skip the effect's passes (one-time warning).

### 5. Running

Run the scene (F5). The first frame binds placeholder textures; temporal accumulation converges over ~`accumulation_frames` frames. Tune via the `settings` resource in the Inspector; `debug_view = Unlit Albedo` shows what the GI bounce multiplies by, `Motion Vectors` shows the velocity buffer used for history reprojection.

### Gotchas (learned the hard way)

- **Spec constants are a no-go on 4.7.2**: the engine's RD compute path silently ignores them (logs `OpSpecConstantComposite is not supported yet.`) and runs with declared defaults. Runtime-configurable shader params in this effect are push-constant fields — keep it that way if you extend the shaders.
- **Shader includes are one level deep only** in the 4.7 glsl importer: an `#include` inside an included `.glsl` survives as a literal and fails to compile. Keep the flat layout (all includes in the entry shader); included files must not include further files.
- Included `.glsl` files must use `importer="keep"` in their `.import` (the entry shaders stay `importer="glsl"`).
- **Never reimport a live effect script from the editor file-watcher while the viewport renders** — on the separate-rendering-thread project it can segfault the editor (render thread runs `_render_setup` on the dying script). After editing effect scripts, restart the editor.
- Hand-written scenes: a NodePath-typed `@export` (e.g. `camera_source`) resolves to NULL silently unless the node line carries `node_paths=PackedStringArray("camera_source")`. The editor adds this attribute on save; if you write `.tscn` by hand, add it yourself.
