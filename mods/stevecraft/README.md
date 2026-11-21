# SteveCraft 0.4.2-alpha — Steve proxy, first-person prototype, and voxel build system

SteveCraft is an independent Lua mod for SM64CoopDX. It is distributed as a
standalone mod ZIP; it does not alter or repackage the Android APK.

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

- All nine starter block IDs still use the vanilla breakable-box display model
  and full-cube collision mesh. They do not yet render the corresponding
  Minecraft Java voxel model or texture.
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

Runtime skin replacement is also not implemented. A PNG alone cannot replace
textures already referenced by a compiled display list; the model needs a
verified dynamic texture-binding path before arbitrary custom skins can work.

## Multiplayer and persistence boundary

The mod attempts to spawn block objects with `spawn_sync_object()` when
available. Grid persistence is stored locally through this mod's Mod Storage;
it is not a server-authoritative world database shared across installations.

## Validation

GitHub Actions checks:

- Lua syntax and generated animation data.
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
