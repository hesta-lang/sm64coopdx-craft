# SteveCraft 0.4.8-alpha — destructible level terrain, local voxel updates and Minecraft block presentation

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

Block placement is assigned to **X** and is edge-latched, so repeated
touch/controller `buttonPressed` events during one held press cannot place
another block. L is no longer required to place blocks; L+B remains the mining
combination.

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

Controls:

| Input | Action |
|---|---|
| X | Place the selected block at the crosshair target |
| L + D-pad Left / Right | Select hotbar slot |
| L + D-pad Up / Down | Raise / lower construction layer |
| Hold L + B | Mine the targeted placed block or a supported level-terrain surface |

Blocks are temporary and scene-local. Starting a new level, changing area,
warping, or loading a different save/scene clears all previous placed blocks.
The inventory remains saved per save slot. The active grid uses 90 SM64 world
units per cell, a maximum of 128 blocks, and dynamic surface objects that load
collision through `load_object_collision_model()`.

### Current block limitations

- The nine starter block types receive Lua-generated cube display lists with
  official Java 26.3 textures. Shared internal faces are culled. A per-face directional shade is
  multiplied into the vertex colors. Each face vertex averages four AO samples:
  the block facing the face, two side neighbors and the diagonal corner;
  air/transparent samples contribute 1.0 and solid blocks 0.2. Glass is
  treated as transparent. This follows the traditional AO formula documented
  by Mojang's Minecraft rendering presentation. The renderer swaps the existing breakable-
  box GeoLayout display-list pointer per object; it does not modify the APK.
- Adjacent SteveCraft blocks omit shared internal faces. A placement/removal
  refreshes only the changed cell's local 3x3x3 neighborhood. A dirty-region
  tracker uses 16x16x16 section coordinates; it does not rebuild the whole area.
  The renderer still uses a separate mesh per unique material/AO pattern rather
  than one combined chunk mesh. The full-cube breakable-box collision mesh is
  unchanged.
- Block PNGs, HUD sprites and OGG samples are embedded by GitHub Actions as a
  Lua Base64 manifest, then written to ModFS through the game's own API. This
  avoids depending on production Lua builds exposing `io.open`.
- Native action-bank sounds (including Mario footsteps, jumps, landings and
  acrobatics) and the Mario voice bank are muted through `HOOK_ON_PLAY_SOUND`.
  Environmental, object and menu banks are left active. Minecraft step samples
  are loaded as ModAudio samples from ModFS and played through the engine's SFX
  sample API. No stream-only volume-channel property is assigned. Failed
  samples are retried rather than permanently marking the audio subsystem unavailable.
- Footstep detection uses the grounded MarioState floor plus forward/horizontal
  velocity fallback for Android builds that do not expose the expected moving
  action flag. Sample gain is raised to audible SFX levels.
- Every placed block is snapped to the exact center of its 90-unit grid cell.
  Pitch, yaw, roll and angular velocity are reset on spawn and every object
  update, so grid blocks do not inherit an incline or drift off the lattice.
- The HUD rejects non-power-of-two textures before calling DJUI, avoiding
  the reported `MPOT width or height` script error. The hotbar, health, hunger
  and armor indicators are larger. Nine 32x32 isometric cube icons are generated
  from the original block textures and embedded as mod-owned resources.
- Resource installation includes a root-manifest fallback for mobile mod-file
  loaders which reject `require("embedded_block_textures")` even when the file
  is present in the ZIP. The package includes the manifest at both root and
  `systems/` paths.
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

### Destructible level environment (0.4.8-alpha)

- In first person, hold **L + B** while aiming at an ordinary level surface to
  mine the collision triangle under the crosshair. The surface is deleted using
  SM64CoopDX's native Lua binding
  `smlua_collision_delete_surface(surface)`, which removes the triangle from
  the engine's spatial collision partitions and frees its surface-pool entry.
- The target is rechecked every frame. The mod snapshots the triangle's type,
  room, vertices and normal before deletion; it never keeps the invalidated
  Surface userdata after the C function returns.
- Destroyed triangles are stored per save slot, level and area. When the engine
  loads that terrain again, `HOOK_ON_ADD_SURFACE` matches the triangle and
  marks it intangible before it enters collision partitions. This hook is
  required for persistence; older builds without it can delete terrain only
  for the current load.
- A dark triangular-prism overlay gives the removed collision triangle a
  visible cavity. This is a rendering mask, not a rewrite of the original
  level GeoLayout: the vanilla map's original display-list triangle remains
  underneath it. Visual fidelity varies with level triangle size/tessellation.
- The mining whitelist only accepts ordinary static terrain types. Dynamic
  object collision, static-object collision, lava, death planes, water,
  quicksand, warps, camera triggers and other special surfaces are protected.
  Terrain mining currently uses a fixed prototype hardness similar to stone;
  it does not yet read per-material Minecraft hardness or spawn inventory
  drops for map geometry.
- This uses the public SM64CoopDX collision-surface API and lifecycle hooks.
  I could not verify that this is the exact internal method used by Swirly;
  no source-level implementation was available to compare.

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
  vertex directional shading, voxel corner ambient occlusion, glass transparency
  and transparent-block AO behavior, and restoration of the vanilla model.
- Binary resource embedding and Base64 decoding for production ModFS import.
- Mario action/voice-bank suppression, SFX sample loading/retry/playback,
  material-to-Minecraft-audio selection, MPOT-safe HUD rendering and isometric
  custom icon loading.
- Embedded DYNOSBIN byte count/header and ModFS import/URI resolution using a
  mocked ModFS API.
- Grid coordinate math, inventory accounting, placement/removal, dynamic
  collision callbacks, temporary scene cleanup, active-grid chunk limits,
  16-block section invalidation, safe static-terrain deletion and destroyed-
  surface persistence encoding.
- First-person camera setup, camera-ray direction, voxel DDA targeting,
  crosshair/HUD rendering, heart mapping and damage thresholds.
- Read-only GeoLayout checks against the original actor binary and Java 26.3
  block resource/runtime metadata.

The shading is a local voxel approximation: it implements face-direction brightness
and Minecraft's four-sample corner AO, not the full 0–15 sky/block light
volumes, flood-fill propagation, dynamic brightness texture or global
shadow-map system. It is intentionally limited to placed SteveCraft blocks so
it does not change lighting across the original SM64 level.

A green CI run proves deterministic tests and package structure pass. It does
**not** prove actual Android audio output, the final visual appearance on the
device, or dynamic collision sizing. Those require an in-game device test.
