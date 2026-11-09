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
2. In your scene, add a `Compositor` node and attach it to `WorldEnvironment.compositor` (or `Camera3D.compositor`).
3. On the `Compositor`, add a `CompositorEffect` and set its script to `SSRT_CE.gd`.
4. Set the effect's `settings` to a new Resource with script `SSRT_settings.gd`.
5. Add a new `SubViewport` node with script `albedo_source_viewport.gd`.
6. Create one new Resource with script `albedo_handoff.gd` and assign it to BOTH the effect's `albedo_handoff` and the SubViewport's `albedo_handoff`.
7. On the SubViewport, set `camera_source` to your main camera.
8. Run the scene (F5).

All parameters are tunable in the Inspector on the `settings` resource. A working reference scene: `src/demo/lumberyard_demo.tscn` (branch `lumberyard-demo`).
