# SteveCraft 0.2.2-alpha — Bedrock-inspired controller prototype

SteveCraft is an independent Lua mod for SM64CoopDX. It does not modify or repackage the Android APK.

## What this build contains

- Keeps the original DynOS actor unchanged at actors/minecraft_steve_geo.bin.
- Resolves the actor's internal GeoLayout symbol as mario_geo.
- Applies the extended model to the existing m.marioObj; it never spawns a second player object.
- Adds a first Lua adaptation of Bedrock's public animation-controller pattern. It observes the local player's action and selects idle, move, jump, fall, or swim states.
- Logs only state transitions, not every frame.

## Important limitations

This is a state-controller prototype, not Bedrock's original player code. Bedrock's internal player physics and camera implementation are proprietary and are not included in bedrock-samples. The public samples document entity components and animation-controller patterns that can be independently recreated.

This build does not alter Mario's movement, gravity, collision, input, camera, or animation playback. Native SM64CoopDX physics remain enabled while DynOS compatibility and model rendering are validated. The controller states are groundwork for later Steve-specific animation and movement stages.

CI validates Lua syntax, the DynOS binary signature, and ZIP contents. A successful package does not prove that the Android runtime can parse or render the actor.
