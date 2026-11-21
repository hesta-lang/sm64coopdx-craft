# SteveCraft 0.2.3-alpha — source-verified model assignment

SteveCraft is an independent Lua mod for SM64CoopDX. It does not modify or repackage the Android APK.

## Current implementation

- Preserves the original DynOS actor at `actors/minecraft_steve_geo.bin` without modifying or regenerating it.
- Resolves its internal GeoLayout symbol as `mario_geo` through `smlua_model_util_get_id()`.
- Assigns the resulting extended-model ID to the existing local player's `m.marioObj` with `obj_set_model_extended()`.
- Reads the model back with `obj_get_model_id_extended()` to verify the assignment against the engine's actual graph-node model ID.
- Keeps Mario's native movement, gravity, collision, camera, and multiplayer proxy behavior unchanged.
- Retains the Bedrock-inspired observational state controller (`idle`, `move`, `jump`, `fall`, `swim`).

## Reverse-engineering findings

Bedrock's public player model is data-driven, not a C++ function we can transplant: `player.entity.json` binds the player identifier to a texture, geometry, scale, animation aliases, and render controllers. `humanoid.custom.geo.json` describes the bone hierarchy and cuboids; animation and render-controller JSON define transforms and visibility.

SM64CoopDX's C/C++ source shows the corresponding native path: DynOS registers a `.geo.bin` actor and its GeoLayout; `smlua_model_util_get_id()` resolves that GeoLayout and returns an extended ID; `obj_set_model_extended()` loads it into DynOS's session model pool and assigns it to an existing object. SteveCraft now verifies the result using `obj_get_model_id_extended()`.

See `ENGINEERING_REVERSE_NOTES.md` for the source files, call flow, format differences, and the next rig-inspection step.

## Current limits

This is not Bedrock's proprietary renderer or player implementation. The public samples reveal the resource/animation definitions, not the internal Bedrock C++ engine. Also, Bedrock's humanoid bone rig is not automatically compatible with the Mario-style DynOS GeoLayout in the current binary. We must inspect and map the actual graph-node hierarchy before writing bone animation code.

CI validates Lua syntax, the DynOS binary signature, and ZIP contents. A successful package does not prove Android runtime rendering or animation compatibility.
