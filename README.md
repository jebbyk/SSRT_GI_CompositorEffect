# SSRT_GI_CompositorEffect
Screen Space Global Illumination Compositor Effect for Godot projects

<img width="720" height="405" alt="p1_00m00-00m38" src="https://github.com/user-attachments/assets/a1df6074-9996-4e1b-acd2-cd6e0f68caab" />

<details>
<summary>Other examples</summary>

<img width="480" height="270" alt="2026-11-11 10-35-43" src="https://github.com/user-attachments/assets/1d50e97c-706a-4a06-9725-86e417930572" />

<img width="720" height="405" alt="p2_00m41-00m53" src="https://github.com/user-attachments/assets/a4900d89-2a12-461f-b97c-f6d709f0fccd" />

<img width="720" height="405" alt="p3_01m00-01m17" src="https://github.com/user-attachments/assets/2b521203-f65f-4127-aa0d-3f9ba6ad9ecb" />

</details>

## Installing SSRT_CE

Godot 4.7.x, Forward+.

1. Copy the `SSRT_CE` folder (in this repository it lives at `src/Features/Graphics/Lighting/SSRT_CE/`) into your project (it works in any location).
2. Create a new `Compositor` resource (FileSystem dock → New Resource → `Compositor`) and assign it to `WorldEnvironment.compositor` in your scene (add a `WorldEnvironment` node if you don't have one), or to `Camera3D.compositor` for a per-camera effect (a camera-attached compositor is invisible in the editor's 3D viewport).
3. In the `Compositor` resource, add an element of type `CompositorEffect` to `compositor_effects` and set its script to `SSRT_CE.gd`.
4. Add a new `SubViewport` node with script `albedo_source_viewport.gd`.
5. Create a new `SSRTAlbedoHandoff` resource (FileSystem dock → New Resource → `SSRTAlbedoHandoff`) and save it (e.g. as `SSRT_CE/albedo_handoff.tres`). Assign the saved file to **both** the effect's `albedo_handoff` (Compositor → `compositor_effects[0]` → property dropdown → Load) and the SubViewport's `albedo_handoff` (property dropdown → Load). Both must point to the same resource — it is the data bridge between the viewport and the effect.
6. *(Optional)* Pin `camera_source` on the SubViewport to a specific camera. If left unset, the albedo mirror automatically follows the main window's active camera — correct for single-camera projects and projects that switch cameras at runtime. Set it only when the game renders through nested viewports or you need a fixed source.
7. Run the scene (F5).

**Note:** if the effect does not take hold right after the setup (no GI change, or unexpected console errors), reload the project first — Project → Reload Current Project. The editor can keep stale script/shader state for resources it imported mid-session.

## Known Limitations

- In the editor's 3D preview, the albedo map is misaligned until the preview is exited; in multi-viewport layouts it may not match the secondary views exactly.
- Without a wired albedo source viewport, the GI bounce falls back to the lit scene color (console warning).
- Without a 3D history texture, temporal accumulation degrades to per-frame estimates (console warning).
- Not compatible with FSR2 upscaling.

## Support

SSRT_CE is free and open source. If it saved you time and you want more of this,
the best way to support me is to grab my game on Steam — every sale gets me
closer to quitting my day job and doing gamedev full time.

<img width="720" height="240" alt="HOTLOOP_720x240_10fps" src="https://github.com/user-attachments/assets/7875c56f-9368-4592-bfd3-53a88e8254ac" />

[![Get it on Steam](https://img.shields.io/badge/Get%20it%20on%20Steam-171A1D?logo=steam&logoColor=white&style=for-the-badge)](https://store.steampowered.com/app/2253660/Hotloop/) 

https://store.steampowered.com/app/2253660/Hotloop/
