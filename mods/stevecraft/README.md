# SteveCraft — standalone mod (alpha)

SteveCraft is packaged as a normal SM64CoopDX mod. It does not patch the
Android APK or add native code to the game executable.

## Player architecture

- Steve has an independent Lua player state, controller and rendered object.
- Mario remains the engine's player/proxy identity for interactions, damage,
  collision, networking and moving platforms.
- Steve's controller owns position and velocity during the supported ground
  and air steps, then mirrors that state into MarioState. Mario is the engine
  compatibility proxy, not a second movement authority.
- The mod hides Mario only after the separate Steve model object exists.
- DynOS compiles the included actor source into the custom Steve model when
  the mod is loaded.

## Model assets

This alpha includes the classic Steve model geometry and 64x64 skin source
from Mojang's bedrock-samples humanoid model. The conversion preserves the
8x8 head, 8x12x4 torso, classic 4-pixel arms and legs, and the second skin
layer (hat, jacket, sleeves and pants), with their UV coordinates.

The generator in tools creates:
- actors/steve/geo.inc.c — articulated GeoLayout for body, head, arms and legs;
- actors/steve/model.inc.c — textured cube meshes and display lists;
- actors/steve/texture.inc.c — the two skin atlas textures;
- two 64x32 PNG atlas halves. Each RGBA16 half occupies at most 4 KiB.

The actor source is generated from source/humanoid.custom.geo.json and
source/steve.png. On mod load, SM64CoopDX's DynOS mod-pack generation step
converts those sources into the steve_geo actor binary. The Lua mod then
loads it through smlua_model_util_get_id.

## Limits

- The GeoLayout preserves separate head, arm and leg joints, but custom
  Minecraft animation clips have not been imported yet.
- The controller is experimental; full Minecraft parity for water, ceilings,
  ladders, knockback, riding and special movement is not complete.
- The Minecraft first-/third-person camera and touch-look behavior are not
  included yet.
- The model and Lua controller still require an in-game visual/physics test.
  CI checks source generation, Lua syntax and ZIP packaging; it does not
  certify in-game rendering or physics.

The PR remains draft until the model, collision bridge and controller have
been tested in SM64CoopDX.
