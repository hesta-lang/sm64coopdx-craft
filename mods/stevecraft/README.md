# SteveCraft — standalone mod (alpha)

SteveCraft is packaged as a normal SM64CoopDX mod. It does not patch the
Android APK, add native code to the game executable, or require rebuilding
SM64CoopDX.

## Player architecture

- Steve has an independent Lua player state, controller and rendered object.
- Mario remains the engine's player/proxy identity so existing systems can
  recognize a normal player for interactions, damage, collision, networking
  and moving platforms.
- Steve's controller owns its position and velocity during supported ground
  and air steps, then mirrors that state into MarioState and Mario's collision
  object. Mario is the compatibility proxy, not a second movement authority.
- SM64's collision queries are reused as the initial compatibility layer.
- The proxy is hidden only after the separate Steve model object exists.
- Unsupported special steps (for example water/hanging states) temporarily
  remain under SM64 control and are copied back into Steve's state.

## Required model asset

The model is not included in this alpha. Add a valid DynOS actor GeoLayout
named `steve_geo` at:

`actors/steve_geo.bin`

The actor must be built for the SM64CoopDX DynOS model loader. Mario remains
visible and vanilla physics remains active when the model cannot be loaded,
preventing a blank/invisible or uncontrollable player.

The current repository does not yet contain a converted Minecraft Steve
GeoLayout, its exact UV/textures, or Steve's animation set. Those assets must
be imported and validated before this mod can display Steve.

## Current scope

Included:
- normal Lua mod entry point (`main.lua`);
- a separate Steve position/velocity state and initial controller;
- ground/air step interception through the public Lua hook;
- SM64 wall/floor queries for the proxy collision layer;
- separate Steve render-object lifecycle and transform attachment;
- Mario proxy visibility management and cleanup;
- standalone ZIP packaging workflow.

Still incomplete:
- exact Minecraft movement constants and full parity with Minecraft physics;
- ceiling, water, swimming, ladders, knockback, riding and all special actions;
- Minecraft first-/third-person camera and touch-look behavior;
- imported Steve mesh, skin UVs, textures and animations;
- full multiplayer proxy synchronization.

The controller is an experimental first pass. Its packaging and Lua syntax are
checked in CI, but the in-game movement and collision behavior still require
testing with the real DynOS Steve model before it should be treated as a
playable release.
