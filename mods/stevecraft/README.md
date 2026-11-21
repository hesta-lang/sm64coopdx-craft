# SteveCraft 0.4.5-alpha — material footsteps, grid-locked blocks, and repaired HUD

SteveCraft is an independent Lua mod for SM64CoopDX. It is distributed as a
standalone mod ZIP; it does not alter or repackage the Android APK.

## Native C engine bridge (0.4.5-alpha)

This release keeps SteveCraft as an independent mod ZIP. It does not ship a
custom `.so`, modify the SM64CoopDX executable, or require a rebuilt APK.

The normal production mod loader exposes the engine's compiled C functions to
Lua, but it does not provide a supported mechanism for loading an arbitrary
C/C++ gameplay library from a mod. New C code that replaces the engine's player
physics would therefore require changing and rebuilding the game executable,
which would break the independent-mod requirement.

Instead, `systems/native_engine.lua` centralizes access to the C features
already present in SM64CoopDX:

- First-person camera control and camera state (`set_first_person_enabled`,
  `get_first_person_enabled`, `first_person_reset`, `gFirstPersonCamera`).
- Native surface and floor collision queries
  (`collision_find_surface_on_ray`, `collision_find_floor`).
- Native angle functions (`sins`, `coss`) and the engine-owned `MarioState`
  position, velocity, action and floor data.
- The engine's object collision, dynamic surface and audio paths.

This is an engine-C-backed integration, **not a new C physics implementation**.
SM64CoopDX still calculates gravity, acceleration, friction, jumping and
collision response. SteveCraft reads that native state and applies Minecraft
presentation and construction logic in Lua. Replacing those movement equations
with Minecraft Java physics while remaining a standalone mod is not supported
by the current public mod-loading interface.

Block placement input is now edge-latched so repeated touch/controller
`buttonPressed` events during one held press cannot place another block.
A fresh press after release is accepted normally.

## Player and model registration

- Mario remains the single engine/player object through the existing
  `m.marioObj`; Steve is not spawned as a second player actor.
- The supplied `actors/minecraft_steve_geo.bin` remains byte-for-byte unchanged.
- The DYNOSBIN is embedded in `model.lua` and imported into the active mod's
  ModFS on first launch. The mod saves it as
  `actors/minecraft_steve_geo.bin` and resolves it through the exact
  `modfs:/<modPath>/actors/minecraft_steve_geo.bin` URI.
- This avoids a dangerous fallback: looking up the internal symbol
  `mario_geo` by itself can resolve the built-in Mario actor when the custom
  actor has not been registered.
- If ModFS or DynOS registration is temporarily unavailable, the loader
  retries rather than permanently caching the first failed lookup.
- Idle and walk animation channels are still generated for the 20 audited
  animated-part channels.

Original actor SHA-256:

`773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1`

## First-person camera and targeting

- Enables SM64CoopDX's native first-person camera API.
- Renders a centered Minecraft-style crosshair while first person is active.
- Uses the camera's actual position/yaw/pitch to construct the crosshair ray.
- Uses a voxel DDA traversal for SteveCraft's dynamic block grid. If the ray
  hits a placed block, the adjacent cell is used for placement and the hit cell
  is used for mining/removal.
- If first person is unavailable or disabled by an engine camera cancel, the
  placement code falls back to Mario's facing direction.

The camera code and ray math are unit-tested. CI does not emulate Android's
touch controls or verify the rendered camera image.

## Hearts, hunger, armor, and damage

- The heart row is derived from the local `MarioState.health` value and maps
  Mario's health range to 20 half-heart units.
- A decrease in Mario health triggers the SM64CoopDX hit-camera shake API.
- Hunger and armor icons are currently visual placeholders. There is no
  Minecraft food depletion, armor inventory, damage absorption, regeneration,
  or hunger-driven health logic yet.

## Inventory and construction

The system has a nine-slot hotbar with 64 starter items per slot. Inventory and
the current selection persist per save slot.

Controls while holding **L**:

| Input | Action |
|---|---|
| L + D-pad Left / Right | Select hotbar slot |
| L + D-pad Up / Down | Raise / lower construction layer |
| L + A | Place the selected block at the crosshair target |
| Hold L + B | Mine the targeted placed block |

The grid is per save slot, level, and area. It uses 90 SM64 world units per
cell, a maximum of 128 blocks per area, chunked Mod Storage records, and
dynamic surface objects that load collision through
`load_object_collision_model()`.

### Current block limitations

- The nine starter block types now receive Lua-generated 24-vertex cube
  display lists with the official Java 26.3 block textures. The renderer
  swaps the existing breakable-box GeoLayout display-list pointer per object;
  it does not add a new compiled actor or modify the APK.
- This is an isolated renderer prototype, not a chunk mesher: each block still
  draws six faces, even when faces are hidden against neighboring blocks.
  The current full-cube breakable-box collision mesh is unchanged.
- Block PNGs, HUD sprites and OGG samples are embedded by GitHub Actions as a
  Lua Base64 manifest, then written to ModFS through the game's own API. This
  avoids depending on production Lua builds exposing `io.open`.
- Native Mario ground-step sound requests are filtered through
  `HOOK_ON_PLAY_SOUND`; only footstep sound IDs are replaced. Jump, landing,
  slide, voice and world sounds remain untouched. SteveCraft plays the Java
  sample selected from the voxel or host-terrain material.
- Every placed block is snapped to the exact center of its 90-unit grid cell.
  Pitch, yaw, roll and angular velocity are reset on spawn and every object
  update, so grid blocks do not inherit an incline or drift off the lattice.
- The HUD now requests the real embedded paths under
  `textures/gui/sprites/hud/` and renders individual sprites. It no longer
  requests the nonexistent `textures/hud/` folder or an unbundled atlas.
- The catalogue includes Java 26.3 destroy speed, explosion resistance,
  friction, and sound-event IDs. Mining time uses a simple prototype scaling
  based on destroy speed; tool tiers and Java's complete breaking-speed
  formula are not implemented.
- Java 26.3 step, place, and break OGG samples are extracted from the official
  asset index, copied into ModFS, and routed through ModAudio. Material-specific
  sound selection is implemented for the supported block families.
- Friction metadata is not yet connected to Mario movement.
- Block-state variants, slabs, stairs, fluids, redstone, crafting and mining
  drops are not implemented.

## First-person hand and custom skins

The crosshair and camera ray are implemented, but a separate first-person
hand is **not included**. A read-only audit of the supplied actor found zero
GeoLayouts named `mario_geo_right_hand`; asking DynOS for that name would risk
falling back to Mario's built-in hand. This version deliberately does not do
that. The correct next step is to extract the hand mesh subtree from the
existing actor binary or add a compatible actor asset that actually contains
a standalone hand layout.

Runtime replacement of Steve's player skin is still not implemented. The
voxel renderer's texture binding only covers the nine construction block
models, not the player actor's compiled materials.

## Multiplayer and persistence boundary

The mod attempts to spawn block objects with `spawn_sync_object()` when
available. Grid persistence is stored locally through this mod's Mod Storage;
it is not a server-authoritative world database shared across installations.

## Validation

GitHub Actions checks:

- Lua syntax and generated animation data.
- Runtime Gfx/Vtx mesh construction, per-object GeoLayout pointer swapping,
  glass transparency layer selection, and restoration of the vanilla model.
- Binary resource embedding and Base64 decoding for production ModFS import.
- Mario step-sound filtering, material-to-Minecraft-audio selection,
  zero-rotation grid transforms and exact embedded HUD resource paths.
- Embedded DYNOSBIN byte count/header and ModFS import/URI resolution using a
  mocked ModFS API.
- Grid coordinate math, inventory accounting, placement/removal, dynamic
  collision callbacks, persistence, chunk limits and per-area reload.
- First-person camera setup, camera-ray direction, voxel DDA targeting,
  crosshair/HUD rendering, heart mapping and damage thresholds.
- Read-only GeoLayout checks against the original actor binary and Java 26.3
  block resource/runtime metadata.

A green CI run proves the deterministic tests and package structure pass. It
does **not** prove that the model renders correctly, that the first-person
camera feels correct with Android touch input, or that dynamic block collision
is correctly sized on a real SM64CoopDX Android build. Those require an
in-game device test.
