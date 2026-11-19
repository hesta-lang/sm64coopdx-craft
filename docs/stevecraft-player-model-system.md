# SteveCraft Player Model System (alpha)

The Player Model System separates a player's rendered model from the legacy
`Character` table and Mario's fixed body GeoLayout.

## Runtime contract

- A player keeps the engine's existing `MarioState` and player object for
  collisions, interactions, networking, and compatibility.
- The visual model is a separate DynOS GeoLayout assigned to that player's
  `GraphNodeObject.sharedChild`. It does not reuse `mario_geo` or Mario's
  arm/leg/head hierarchy.
- Each player index has its own model profile, scale, and optional named
  animation.
- If no profile is selected, the existing character renderer is unchanged.
- In local proxy mode, selecting a profile makes the custom GeoLayout visible
  in place of the hidden Mario mesh.

## Lua API

```lua
local steveModel = smlua_model_util_get_id("steve_geo")

assert(stevecraft_player_model_set_model(0, steveModel))
assert(stevecraft_player_model_set_scale(0, 1.0, 1.0, 1.0))

-- Register this animation first with smlua_anim_util_register_animation.
assert(stevecraft_player_model_set_animation(0, "steve_idle"))

-- Restore the player's original model when leaving Steve mode.
stevecraft_player_model_clear(0)
```

The model ID must be the extended ID returned by
`smlua_model_util_get_id`. The animation name must already have been
registered with `smlua_anim_util_register_animation`.

## Animation behavior

When no named animation override is selected, DynOS can continue to use the
actor's animation table and the engine's current Mario animation index. When
a named custom animation is selected, it is bound directly to that player's
render object. The player render flag remains enabled while the profile is active,
so the scene graph also performs its player-specific bone calculations. The DynOS
animation swapper will not replace a named custom
animation with one selected from Mario's vanilla animation index. The model
layer preserves Mario's current action-animation ID as a compatibility marker
while changing the rendered animation data, so Mario's animation setter does
not overwrite the independent animation on the next update.

## Limits of this stage

This changes model selection and animation binding; it does not extract
Minecraft geometry, convert Minecraft UVs, generate Steve's skeleton, or
import Minecraft animation assets automatically. Steve still needs a valid
DynOS actor/GeoLayout and animation data converted into formats supported by
the SM64CoopDX renderer. Physics and camera integration remain separate.
