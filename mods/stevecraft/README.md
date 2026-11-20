# SteveCraft — standalone mod (alpha)

SteveCraft is packaged as a normal SM64CoopDX mod. It does not patch the
Android APK, add native code to the game executable, or require rebuilding
SM64CoopDX.

## Player architecture

- Steve is a separate rendered object with an independent DynOS model.
- Mario remains the engine's player/proxy identity so existing systems can
  continue to recognize a normal player for interactions, damage, collision,
  networking and moving platforms.
- The proxy is hidden only after Steve's model object has been created.
- Steve's visual transform is attached to the proxy transform in this first
  integration stage. This deliberately avoids two competing physics owners.

## Required model asset

The model is not included in this alpha. Add a valid DynOS actor GeoLayout
named \`steve_geo\` at:

\`actors/steve_geo.bin\`

The actor must be built for the SM64CoopDX DynOS model loader. Mario remains
visible when the model cannot be loaded, preventing a blank/invisible player.

The current repository does not yet contain a converted Minecraft Steve
GeoLayout, its exact UV/textures, or Steve's animation set. Those assets must
be imported and validated before this mod can display Steve.

## Current scope

Included:
- normal Lua mod entry point (\`main.lua\`);
- separate Steve render-object lifecycle;
- Mario proxy visibility management;
- transform attachment and cleanup on object unload/warp;
- standalone ZIP packaging workflow.

Not included yet:
- Minecraft movement/physics replacing Mario's movement;
- Minecraft first-/third-person camera;
- imported Steve mesh, skin UVs and animations;
- full multiplayer proxy synchronization.

The next implementation stage must make Steve's controller the movement
authority and write the resulting transform/state back to Mario's proxy,
while keeping the engine's collision and interaction contracts intact.
