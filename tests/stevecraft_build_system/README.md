# SteveCraft build-system tests

Runs the same Lua 5.4 inventory and grid implementation that is embedded in
mods/stevecraft/main.lua. SM64CoopDX's object, storage, spawn, hook, and HUD
functions are mocked so CI can test deterministic gameplay logic without an
Android game process.

Coverage:
- Java 26.3 starter block metadata and 9-slot hotbar.
- Grid coordinate conversion and forward placement target.
- Per-cell uniqueness, block placement and inventory decrement.
- Surface-object initialization, collision pointer, scaling, and per-frame
  load_object_collision_model() update.
- Block removal, dynamic object deactivation, and inventory refund.
- Unbreakable bedrock and safe rejection when there is no inventory space.
- Input consumption while the build modifier is held.
- HUD output, per-save/per-level/per-area storage, reload and chunk limits.
- Maximum number of blocks per area.

CI does not render the placeholder block model or its collision in the Android
app. The current block appearance uses SM64CoopDX's vanilla breakable-box model
scaled to the grid cell; it is a working collision prototype, not yet the
Minecraft texture/model renderer. Precise camera raycast placement is also
not in this stage.
