# SteveCraft 0.2.4-alpha — articulated proxy with math-generated animations

SteveCraft is an independent Lua mod for SM64CoopDX. It is distributed as a
standalone mod ZIP and does not modify or repackage the Android APK.

## Current implementation

- Preserves the original DynOS actor at `actors/minecraft_steve_geo.bin`; it is not modified or regenerated.
- Resolves the internal GeoLayout symbol `mario_geo` through `smlua_model_util_get_id()`.
- Assigns the resulting extended-model ID to the existing local player's `m.marioObj` with `obj_set_model_extended()`.
- Reads the model ID back with `obj_get_model_id_extended()` to verify the assignment.
- Keeps Mario's native movement, gravity, collision, camera, and multiplayer proxy behavior unchanged.
- Observes `idle`, `move`, `jump`, `fall`, and `swim` states.
- Generates 24-frame idle and walking animations in Lua using sinusoidal functions, registers them through `smlua_anim_util_register_animation()`, and applies them to the same `marioObj`.
- Uses all 20 `GEO_ANIMATED_PART` channels in the existing GeoLayout; no second actor is spawned.

## Verified rig layout

The original binary SHA-256 is:

`773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1`

The read-only audit found a balanced `mario_geo` layout with 361 words, 215 commands, 20 animated parts, and zero custom DynOS `GEO_BONE` nodes. Its part traversal matches the 20 `MarioAnimPart` entries in SM64CoopDX: root, butt, torso, head, upper/forearm/hand groups for both arms, and upper/lower groups for both legs.

The animation format reserves three root-translation channels (six index entries) when `ANIM_FLAG_6` is used. The 20 animated parts then consume three rotation channels each. The generator therefore creates 63 channel index pairs and 1,440 sampled values per animation (24 frames × 20 parts × 3 axes).

## Animation behavior

- **Idle:** subtle torso breathing and counter-motion in the head.
- **Walking:** opposing left/right arm and thigh swings, with small elbow bends.
- **Other states:** currently use the idle pose. Dedicated jump, fall, and swim animations are not yet implemented.

The current walk amplitude is approximately 30 degrees. The angle values use SM64's signed 16-bit full-turn representation.

## Minecraft Java research pipeline

The research workflow targets Minecraft Java 26.3 and exports block resource metadata plus live registry values from a temporary Fabric dedicated server. It records block IDs, states, blockstate model references, model cuboids, tags, recipes, sounds, destroy speed, blast resistance, friction, collision shapes, and related fields.

World-dependent collision and redstone values are explicitly marked as contextual samples rather than universal properties. The temporary research artifacts are separate from the standalone player mod ZIP.

## Validation limits

GitHub Actions validates the extractor, Java runtime registry, original binary checksum and GeoLayout, animation formulas, channel offsets, integer ranges, and Lua syntax. CI does not render the animation on an Android device. The visual result and joint directions still require an in-game test; do not treat a successful workflow as proof of correct on-device appearance.
