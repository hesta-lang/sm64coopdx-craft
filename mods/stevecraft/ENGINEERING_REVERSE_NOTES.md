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
