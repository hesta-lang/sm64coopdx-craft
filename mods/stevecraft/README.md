# SteveCraft 0.3.0-alpha — Steve proxy, block grid, and inventory prototype

SteveCraft is an independent Lua mod for SM64CoopDX. It is packaged as a
standalone mod ZIP; it does not alter or repackage the Android APK.

## Player and model

- Keeps Mario as the single engine/physics proxy through the existing
  m.marioObj; it does not spawn a second player actor.
- Preserves the original DynOS actor at
  mods/stevecraft/actors/minecraft_steve_geo.bin. The file is not regenerated.
- Resolves the internal GeoLayout symbol mario_geo through
  smlua_model_util_get_id() and assigns it using obj_set_model_extended().
- Retains native SM64CoopDX gravity, movement, camera, and player collision.
  Full Minecraft Java player physics is not implemented yet.
- Generates 24-frame idle and walking animation loops using Lua trigonometric
  functions and the model's 20 audited animated-part channels.

Original actor SHA-256:

773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1

## Invisible per-map construction grid

Each save slot, level, and area gets its own grid, anchored to world origin.
The grid itself is invisible; a placed block occupies one integer cell. Grid
coordinates are converted into SM64 world coordinates using 90 game units per
cell.

- Maximum 128 placed blocks per area in this prototype.
- Occupied cells cannot be overwritten.
- Each placed block is spawned as an SM64CoopDX surface object.
- The object loads its collision every update using
  load_object_collision_model(). Removing a block deactivates that object,
  which removes its dynamic collision.
- Grid records are persisted with the mod's own storage, split into chunks
  shorter than its per-key value limit.
- Returning to the same save slot/level/area reconstructs the saved blocks.
  Switching areas deactivates the old area's block objects.

### Current controls

Hold **L** to enter build controls:

| Input | Action |
|---|---|
| L + D-pad Left / Right | Select hotbar slot |
| L + D-pad Up / Down | Raise / lower construction layer |
| L + A | Place the selected block in the cell in front of Steve |
| L + B | Remove the block in the target cell |

Placement currently uses Steve's facing direction and a fixed forward distance,
not a camera raycast. Vertical placement uses the selected layer offset.

## Inventory and starter blocks

The HUD shows a 9-slot hotbar. Each slot starts with 64 units, creating a
creative-mode-style starter inventory. The selected slot and stack counts are
saved per mod save slot. Breaking a block returns one item to its matching
stack or an empty slot. A block is not removed when the inventory has no room
for the returned item.

The initial catalogue contains nine Minecraft Java 26.3 block IDs:

- Stone
- Dirt
- Grass block
- Oak planks
- Cobblestone
- Glass
- Bricks
- Sand
- Bedrock

Destroy speed, explosion resistance, friction, and sound-event IDs for this
starter catalogue were transcribed from the validated Java 26.3 runtime-registry
artifact. Bedrock has destroy speed -1 and cannot be removed through this
prototype.

## Collision and rendering limits

The current visual and collision prototype uses SM64CoopDX's vanilla breakable
box model and collision mesh, scaled to the grid cell. This proves the object
spawn, persistence, and dynamic surface-collision path, but it does **not**
render the actual Minecraft block textures or per-block model geometry yet.
At this stage the nine starter blocks all use a full-cube collision and the
same placeholder appearance. Their Java-specific friction and sound IDs are
catalogue data only; different movement friction and Minecraft audio playback
have not been wired in.

The current build is also not yet a complete Minecraft world simulator:
there is no crafting system, mining progress, block-state variants, fluids,
redstone simulation, camera-ray block selection, or Java-equivalent player
physics. These must be built and validated in later stages.

## Multiplayer and persistence boundary

The mod attempts to spawn blocks with spawn_sync_object() so the objects can
participate in the current SM64CoopDX multiplayer session. If synchronized
spawning is unavailable, it falls back to a local object. Mod storage is local
to this mod installation/save slot; it is not a server-authoritative shared
world database. Persistent construction across different players or devices
is not claimed by this version.

## Validation

GitHub Actions checks:
- Minecraft Java 26.3 resource extraction and live block registry inspection.
- Original actor checksum, DynOS GeoLayout hierarchy, and its 20 animation channels.
- Idle/walk animation formulas and index/value bounds.
- Grid coordinates, inventory accounting, placement/removal, object collision
  setup, storage chunk lengths, per-area reload, input consumption, and block
  capacity using mocked SM64CoopDX APIs.

CI does not render the placeholder blocks or verify collision dimensions on an
Android device. The 90-unit cell size and 0.45 model scale are the initial
prototype mapping and require an in-game Android check before being treated as
final Minecraft-sized geometry.
