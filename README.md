# SSRT_GI_CompositorEffect
Screen Space Global Illumination Compositor Effect for Godot projects

<img width="720" height="405" alt="p1_00m00-00m38" src="https://github.com/user-attachments/assets/a1df6074-9996-4e1b-acd2-cd6e0f68caab" />

<img width="720" height="405" alt="p2_00m41-00m53" src="https://github.com/user-attachments/assets/a4900d89-2a12-461f-b97c-f6d709f0fccd" />

<img width="720" height="405" alt="p3_01m00-01m17" src="https://github.com/user-attachments/assets/2b521203-f65f-4127-aa0d-3f9ba6ad9ecb" />

<img width="720" height="405" alt="p4_01m22-01m52" src="https://github.com/user-attachments/assets/349ba2e6-5c32-41c1-9c84-7cc51cfd37ca" />

<img width="720" height="405" alt="p6_02m15-02m36" src="https://github.com/user-attachments/assets/0a686e76-fdbb-4cf9-b493-9f7c4a97f087" />

## Installing SSRT_CE

Godot 4.7.x, Forward+.

1. Copy the `SSRT_CE` folder into your project (it works in any location).
2. Create a new `Compositor` resource (FileSystem dock → New Resource → `Compositor`) and assign it to `WorldEnvironment.compositor` in your scene (add a `WorldEnvironment` node if you don't have one), or to `Camera3D.compositor` for a per-camera effect (a camera-attached compositor is invisible in the editor's 3D viewport).
3. In the `Compositor` resource, add an element of type `CompositorEffect` to `compositor_effects` and set its script to `SSRT_CE.gd`.
4. Add a new `SubViewport` node with script `albedo_source_viewport.gd`.
5. Assign the effect's auto-created `albedo_handoff` to the SubViewport's `albedo_handoff`.
6. On the SubViewport, set `camera_source` to your main camera.
7. Run the scene (F5).

## Known Limitations

- In the editor's 3D preview, the albedo map is misaligned until the preview is exited; in multi-viewport layouts it may not match the secondary views exactly.
- Without a wired albedo source viewport, the GI bounce falls back to the lit scene color (console warning).
- Without a 3D history texture, temporal accumulation degrades to per-frame estimates (console warning).
