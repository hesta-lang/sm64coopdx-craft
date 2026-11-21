# SteveCraft — Reverse-engineering notes: Bedrock player model vs. SM64CoopDX

These notes document a source-based reconstruction of the public model-registration and rendering paths. They do not claim access to Minecraft Bedrock's proprietary engine implementation.

## 1. How Bedrock defines Steve

Official sample files:

- `resource_pack/entity/player.entity.json` declares `minecraft:player` as a client entity.
- The client entity maps its default texture to `textures/entity/steve`.
- It maps its default geometry to `geometry.humanoid.custom`.
- It declares a scale of `0.9375`, animation aliases, a root animation controller, render controllers, and attachable support.
- `resource_pack/models/entity/humanoid.custom.geo.json` defines the geometry and its named bones.
- `resource_pack/animations/player.animation.json` defines transforms for bones such as `head`, `body`, `leftarm`, `rightarm`, `leftleg`, and `rightleg`.
- `resource_pack/animation_controllers/player.animation_controllers.json` selects animations based on state and query expressions.
- `resource_pack/render_controllers/player.render_controllers.json` selects geometry, material, texture, and visible body parts for first-person, third-person, spectator, and map views.

Therefore, the public Bedrock model path is data-driven: client-entity definition -> geometry + texture -> animation aliases/controllers -> render controllers. The JSON and Molang expressions are interpreted by Bedrock; they are not C++ source code that can be copied into a mod.

## 2. How SM64CoopDX loads a custom player model

The public SM64CoopDX source exposes this path:

1. DynOS registers custom actor assets from the mod filesystem. `DynOS_Actor_AddCustom()` reads the `.geo.bin`, obtains its GeoLayout data, and calls `DynOS_Model_LoadGeo()` to create a graph node in the session model pool.
2. `DynOS_Actor_GetLayoutFromName()` searches registered level layouts, custom actors, loaded actors, built-in actors, and then ModFS actor files.
3. `smlua_model_util_get_id(name)` calls `dynos_geolayout_get(name)`. If the named GeoLayout cannot be found, it returns `E_MODEL_ERROR_MODEL`. Otherwise it returns or creates a Lua extended-model ID.
4. `smlua_model_util_load(extId)` loads the GeoLayout into the DynOS session pool and returns the ordinary engine model ID.
5. `obj_set_model_extended(object, extId)` calls the model loader and then the engine's `obj_set_model()` on that existing object.
6. `obj_get_model_id_extended(object)` reads the object's current graph-node model and converts it back to an extended-model ID. SteveCraft uses this as a read-back check after assignment.

Relevant engine source files:

- `data/dynos_mgr_actor.cpp` — custom actor registration and GeoLayout lookup.
- `data/dynos_mgr_models.cpp` — graph-node/model pool allocation and ID registration.
- `src/pc/lua/utils/smlua_model_utils.c` — GeoLayout lookup, extended model IDs, and loading.
- `src/pc/lua/utils/smlua_obj_utils.c` — `obj_set_model_extended()` and `obj_get_model_id_extended()`.
- `docs/lua/examples/koopa-player-model/main.lua` — official example that calls `smlua_model_util_get_id()` and assigns it to `m.marioObj` with `obj_set_model_extended()`.

## 3. SteveCraft implementation

SteveCraft follows the engine's supported Lua route rather than reproducing DynOS internals:

```lua
local modelId = smlua_model_util_get_id("mario_geo")
if modelId ~= E_MODEL_ERROR_MODEL then
    obj_set_model_extended(m.marioObj, modelId)
    local currentId = obj_get_model_id_extended(m.marioObj)
    assert(currentId == modelId)
end
```

The production mod uses guarded calls rather than `assert`, so runtime problems are logged instead of crashing the mod.

The current binary remains unchanged at `actors/minecraft_steve_geo.bin`. Its resolved internal GeoLayout symbol is `mario_geo`. The model is assigned to the existing local-player `m.marioObj`; no second actor is spawned and the APK is not modified.

### Bedrock's actual player rig and layered animation model

The public `geometry.humanoid.custom` geometry uses these main hierarchy elements:

- `root`
- `waist` (child of `root`)
- `body` (child of `waist`)
- `head` and `hat` (head is child of body; hat is child of head)
- `leftArm` -> `leftSleeve` and `leftItem`
- `rightArm` -> `rightSleeve` and `rightItem`
- `leftLeg` -> `leftPants`
- `rightLeg` -> `rightPants`
- `jacket` (child of body)
- `cape` (child of body)

The player root animation controller has separate first-person, third-person, map-player, and paperdoll states. In third person it layers a base pose, look-at, arm movement, leg movement, cape, holding, sneak, swim/crawl, sleeping, attack, and item animations. This is not a simple one-state-at-a-time idle/walk/jump switch.

The public player definition computes a shared walk-cycle phase from `query.modified_distance_moved` and `query.modified_move_speed` in `variable.tcos0`. `animation.player.move.arms` applies opposite rotations to the arms; `animation.player.move.legs` applies opposing leg rotations scaled by 1.4. These equations can be translated to Lua after the target SM64CoopDX bone/joint mapping is known.

### Why the next step is a rig audit

The Bedrock rig names above are case-sensitive identifiers used to match animation channels. The current DynOS asset's mesh labels are Mario-style, so a direct transfer of `leftArm`/`rightArm`/`leftLeg` names is not justified. First document the actual GeoLayout branch and animated-part order inside `mario_geo`; then construct an explicit mapping table from Bedrock body roles to existing SM64 joints. If no matching joints exist, a new rigged asset is required—but that would be a separate, explicit model-authoring step, not a Lua camera/physics tweak.

## 4. Important differences and limits

- Bedrock's player geometry has a humanoid bone hierarchy. A DynOS `.geo.bin` is a compiled GeoLayout/display-list asset. They are not interchangeable formats.
- Bedrock render controllers can independently select textures, materials, geometry, and part visibility. SM64CoopDX's `obj_set_model_extended()` only assigns a model graph to an object; texture/render details are encoded in or referenced by the DynOS actor data and rendering pipeline.
- The present Steve binary has an internal Mario-named GeoLayout and Mario-style mesh/display-list naming. Do not assume its skeleton is automatically the same as Bedrock's `root/body/waist/head/leftArm/rightArm/leftLeg/rightLeg` rig.
- Bedrock's internal C++ player renderer, skin selection, first-person arm renderer, and entity pipeline are proprietary. The public samples document the resource definitions, not those engine implementation details.

## 5. What to investigate next

Before changing geometry or animation code, inspect the actual DynOS GeoLayout and graph-node hierarchy used by `mario_geo`, then map each available animated part to the desired Bedrock bone roles. Only after that mapping is verified should an animation adapter be written. This prevents guessing bone names or applying transforms to the wrong nodes.

## Public source references

- Bedrock player entity: https://github.com/Mojang/bedrock-samples/blob/main/resource_pack/entity/player.entity.json
- Bedrock humanoid geometry: https://github.com/Mojang/bedrock-samples/blob/main/resource_pack/models/entity/humanoid.custom.geo.json
- Bedrock player animations: https://github.com/Mojang/bedrock-samples/blob/main/resource_pack/animations/player.animation.json
- Bedrock player render controllers: https://github.com/Mojang/bedrock-samples/blob/main/resource_pack/render_controllers/player.render_controllers.json
- SM64CoopDX model utils: https://github.com/coop-deluxe/sm64coopdx/blob/main/src/pc/lua/utils/smlua_model_utils.c
- SM64CoopDX object utils: https://github.com/coop-deluxe/sm64coopdx/blob/main/src/pc/lua/utils/smlua_obj_utils.c
- SM64CoopDX DynOS actor loader: https://github.com/coop-deluxe/sm64coopdx/blob/main/data/dynos_mgr_actor.cpp
- Official custom player model example: https://github.com/coop-deluxe/sm64coopdx/blob/main/docs/lua/examples/koopa-player-model/main.lua

## 6. Read-only audit of the actual Steve actor binary

The original `mods/stevecraft/actors/minecraft_steve_geo.bin` was decoded
read-only using the DynOS compression and GeoLayout record format. The file
was not regenerated or modified. Its SHA-256 is pinned in the rig-audit tool:

`773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1`

Verified facts for the `mario_geo` record:

- 361 GeoLayout words and 215 commands.
- 62 `GEO_OPEN_NODE` and 62 `GEO_CLOSE_NODE` commands; the hierarchy balances.
- 20 `GEO_ANIMATED_PART` nodes, in the traversal order used by the layout.
- Zero custom DynOS `GEO_BONE` nodes.
- Distinct animated-part display lists reference the torso, left/right forearms,
  and left/right legs. The head mesh is referenced from a separate
  `GEO_DISPLAY_LIST` node inside the articulated subtree.
- The layout also contains branches to optional layouts (for example
  `mario_geo_opt_1` to `mario_geo_opt_7`) and function/switch nodes.

The animated-part indices are not interchangeable with Bedrock's named bones.
Indices are positional engine channels. A tentative body-role reading of the
hierarchy must be confirmed from the complete child graph and animation format;
this audit deliberately reports the exact joint order and embedded references
instead of inventing a name for every empty pivot.

### Consequence for Lua math animation

The existing binary is not a flat six-cube model. It already has an articulated
Mario-style GeoLayout with 20 animation-part nodes. This gives a possible path
to generate keyframe channels from trigonometric functions and register them
through `smlua_anim_util_register_animation()`. However, the custom animation
API accepts raw `values` and `index` arrays. Before using it on Steve, we must
validate the precise channel/index layout expected by SM64CoopDX for these 20
nodes, including root translation channels. The read-only audit does not yet
prove that mapping, and no animation has been applied yet.

The read-only inspector and tests are in `tools/stevecraft_rig_audit/` and
`tests/stevecraft_rig_audit/`. The research workflow runs them only after the
Minecraft Java runtime registry stage succeeds. The original actor binary is
also checksum-pinned so future packaging or animation work cannot silently
replace it.

## 7. Math-generated animation channels on the audited rig

The SM64CoopDX renderer increments `MarioBodyState.currAnimPart` at each
`GEO_ANIMATED_PART` and uses the corresponding order from
`enum MarioAnimPart` in `include/types.h`. The audited Steve layout has 20
animated nodes in that traversal order. The first channel indices correspond
to root translation; with `ANIM_FLAG_6` (`0x40`), `anim_process()` skips
these three translation channel pairs and then processes three rotation
channels (X/Y/Z) for each of the 20 animated parts.

Relevant source behavior:

- `src/game/rendering_graph_node.c::anim_process()` consumes translation
  channels when translation is enabled, then always consumes three rotation
  channels; it changes the global animation type from translation to rotation.
- The `ANIM_TYPE_NO_TRANSLATION` branch advances the attribute pointer by six
  index entries (three channel pairs) before reading root rotation channels.
- `geo_process_animated_part()` uses the same current animation attribute
  pointer and advances it for each animated part.
- `src/pc/lua/utils/smlua_anim_utils.c` copies Lua-provided values and index
  arrays into a custom `Animation`, and its setter assigns that animation to
  the supplied object's `animInfo.curAnim`.
- `include/types.h` defines the 20 MarioAnimPart channels and the Animation
  structure. Each attribute is an index pair: maximum frame count and zero-based
  offset into the signed 16-bit values array.

The first generated implementation creates 24-frame idle and walk loops:
- Idle uses a small sinusoidal torso rotation and opposite head counter-motion.
- Walk uses opposite sinusoidal left/right arm and thigh rotation, plus small
  elbow bends.
- It creates three reserved root-translation pairs followed by 60 rotation
  channel pairs. Each animation therefore has 126 index entries and 1,440
  signed-16-bit values.

The Lua generator is tested by `tests/stevecraft_animation/test_animation.lua`.
It checks exact array lengths, index bounds, integer range, 24-frame phase
values, and opposing left/right limb motion. The research workflow runs this
stage only after the Java block registry and original GeoLayout audit pass.

Important limitation: CI tests the mathematical output and API contract, not
the final Android rendering. The first device test must check limb direction,
pose scale, camera framing and whether the animation changes from idle to walk
without affecting Mario's collision or position. Jump, fall and swim animations
remain a subsequent stage and currently resolve to the idle pose.

## 8. Invisible block grid, inventory, and dynamic collision prototype

The first construction implementation uses SM64CoopDX's supported Lua surface
object path rather than attempting to alter the map's static collision blob.
The block behavior is registered with `hook_behavior(..., OBJ_LIST_SURFACE,
true, init, loop)`. Its initializer assigns the existing breakable-box
collision resource and sets object drawing/collision range. The behavior loop
calls `load_object_collision_model()` every update, as required by the engine
API for object collision. The engine transforms the collision vertices with
the object's position, orientation, and scale before inserting dynamic
surfaces into its spatial partition.

The current grid:
- Uses integer XYZ cell coordinates with a 90-SM64-unit cell width and is
  anchored at world origin.
- Is scoped by current save slot, level number, and area index.
- Is intentionally invisible; the grid is data, not a rendered floor or wireframe.
- Enforces one block per cell and a prototype limit of 128 blocks per area.
- Saves compact cell records through mod_storage in chunks no longer than 800
  characters, below SM64CoopDX mod-storage's per-value limit.
- Reconstructs block objects when the user returns to that save/level/area.
- Deactivates the old area's block objects on area changes and warps.

The hotbar is nine slots with 64 items preloaded per slot, which is a
creative-mode test inventory rather than a survival progression system. It
persists the selected slot and stack counts per save slot. When the player
breaks a block, it is only removed if the matching stack or an empty slot can
accept the returned item. Bedrock has destroy speed -1 and is rejected by the
removal path.

Controls while holding L:
- D-pad Left/Right changes the selected slot.
- D-pad Up/Down changes the build layer.
- A places the selected block in the grid cell in front of Steve.
- B removes the block in that target cell.

This first version intentionally does not yet perform a camera raycast; the
target is calculated from Mario's facing yaw and a fixed forward distance.
The native block object uses the vanilla breakable-box display model and
collision mesh scaled to the cell. That means collision is engine-backed and
real, but the visual is still a placeholder rather than the correct Minecraft
block model/texture. All nine starter blocks currently use the same full-cube
collision mesh. The Java registry's friction and sound IDs are retained in the
catalogue, but do not yet alter SM64 movement or trigger Minecraft sounds.

Multiplayer boundary: the mod attempts `spawn_sync_object()`, so block
objects can synchronize during a live session. The mod's storage file is local
to the installation/save slot and is not a server-authoritative persistent
shared world. Cross-device world persistence has not been implemented.

CI tests use mocked object, behavior, storage, and HUD APIs to check the
grid/inventory logic. A successful test cannot substitute for Android
verification of model scale, collision volume, block placement reach, and
multiplayer behavior. This is the first dynamic-block prototype, not the final
Minecraft voxel renderer or Java player-physics port.


## 0.4.1-alpha — custom actor registration and first-person hand

### Why the previous model lookup could select the wrong actor

SM64CoopDX's `smlua_model_util_get_id(name)` resolves a GeoLayout name via
DynOS. DynOS first looks through active levels, registered custom actors and
loaded actors, then built-in actors. The string `mario_geo` is a built-in
layout name. If the custom actor has not been added to DynOS, resolving that
string can return Mario instead of Steve.

A custom actor binary is loaded when DynOS receives its ModFS URI
(`modfs:/<modPath>/<file>`). Placing a `.bin` in the mod's ordinary ZIP
directory does not by itself create that ModFS entry. The 0.4.1-alpha loader
therefore embeds the original DYNOSBIN as base64, imports the decoded bytes to
`actors/minecraft_steve_geo.bin` in the active ModFS, persists the ModFS, and
passes its URI to `smlua_model_util_get_id`. It never falls back to
`mario_geo`; failed registration is retried with a cooldown.

CI checks that the embedded bytes are exactly equal to the original binary
and that the ModFS import/URI path works against a mocked API. This is not a
substitute for loading the actor on Android.

### First-person hand extraction audit

The initial implementation tried to resolve `mario_geo_right_hand` after the
Steve actor registered. The read-only rig audit found **zero** layouts with
that name in `minecraft_steve_geo.bin`. This lookup is unsafe because DynOS
checks built-in layouts after custom/loaded actors; it could therefore return
Mario's built-in hand. The standalone hand renderer has been removed rather
than showing the wrong model. A future extractor must locate and expose the
actual hand display-list subtree from this actor, or add a separately verified
SM64CoopDX-compatible hand asset before a camera-relative object is added.

### Remaining gaps

The Minecraft block catalogue's hardness and sound-event identifiers are
metadata; actual Minecraft textures, block meshes, per-shape collision,
Minecraft sound playback, and runtime skin texture replacement are still not
implemented in 0.4.1-alpha. Hunger and armor bars remain nonfunctional visual
indicators; hearts are driven by Mario's health and damage triggers the native
camera shake callback.


## 0.4.2-alpha — duplicate placement, modular systems, official Minecraft assets

### Placement and object lifetime

SM64CoopDX surface objects are created by registering one behavior with
\`hook_behavior(..., OBJ_LIST_SURFACE, ...)\` and spawning a single object for
each placed grid cell. The object's loop updates its transformed collision with
\`load_object_collision_model()\`. The upstream reference implementation is
the engine's Lua surface-collision example:

- https://github.com/coop-deluxe/sm64coopdx/blob/master/docs/lua/examples/behavior-surface-collisions.lua

\`spawn_sync_object\` is the preferred path because it creates a network-aware
object. The local \`spawn_non_sync_object\` path is a fallback only for builds
where the sync API is absent; a nil sync result is not proof that the engine
did not create the synchronized object. The placement function also guards
the same grid cell and world key against duplicate attempts within one
\`gGlobalTimer\` frame. This makes repeated input idempotent for that cell.
The Android game still needs a multiplayer/device test to confirm object
ownership and network event ordering.

### Official Minecraft HUD and resources

The package workflow resolves Minecraft Java 26.3 through Mojang's official
version manifest and asset index:
https://piston-meta.mojang.com/mc/game/version_manifest_v2.json

The extractor verifies every downloaded resource against the SHA-1 hash in
that asset index and stores the original HUD sprites, block texture PNGs and
selected block step/place/break OGG samples under the mod's \`assets/\` folder.
At runtime, \`systems/assets.lua\` copies them into this mod's ModFS and loads
the GUI sprites through \`get_texture_info(modfs_uri)\`; audio samples are
registered by \`systems/sounds.lua\`.

The visible HUD renderer uses the actual Java GUI sprite artwork for hotbar,
selection, crosshair, hearts, food and armor. Its position/scaling and the
remaining state behaviour are an SM64CoopDX adaptation, not a byte-for-byte
port of Minecraft's GUI code. The XP bar is drawn only as a background until
an XP progression system exists.

The block textures are imported and used for hotbar item icons, but the
placed cube's display list still uses the SM64 breakable-box placeholder.
A dedicated cube DynOS actor with the correct six-face texture bindings is
still required before the in-world blocks visually become Minecraft blocks.

### Split subsystem files

The mod now loads the following independent Lua modules from \`systems/\`:

- \`blocks.lua\`: same-frame placement guard and block-object lifecycle helpers.
- \`physics.lua\`: friction/ground-contact adapters; this is not yet a complete
  Minecraft Java movement replacement.
- \`camera.lua\`: first-person forward vector used by crosshair ray targeting.
- \`hud.lua\`: source-sprite HUD renderer and normalized Java HUD layout.
- \`sounds.lua\`: OGG sample registration and block/footstep event router.
- \`models.lua\`: ModFS URI and custom model resolver helpers.
- \`assets.lua\`: packaged resource installation and texture resolution.

\`main.lua\` remains the coordinator and retains the existing model-import,
world-state and Mario proxy code. The split is incremental: the remaining
engine-facing routines still need to move behind these module interfaces as
their dependencies are separated and tested.
