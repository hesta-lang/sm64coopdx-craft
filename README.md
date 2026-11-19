![sm64coopdx Logo](textures/segment2/custom_coopdx_logo.rgba32.png)

sm64coopdx is an online multiplayer project for the Super Mario 64 PC port that synchronizes all entities and every level for multiple players. The project was started by the Coop Deluxe Team. The purpose is to actively maintain and improve, but also continue sm64ex-coop, created by djoslin0. More features, customization, and power to the Lua API allow modders and players to enjoy Super Mario 64 more than ever!

Feel free to report bugs or contribute to the project.

Contains some code from:\
[AloXado320/sm64ex-alo](https://github.com/AloXado320/sm64ex-alo) \
[VDavid003/sm64-port-android](https://github.com/VDavid003/sm64-port-android) \
[VDavid003/sm64-port-android-base](https://github.com/VDavid003/sm64-port-android-base) \
[porcino/sm64-port-android](https://github.com/porcino/sm64-port-android) \
[robertkirkman/sm64ex-coop](https://github.com/robertkirkman/sm64ex-coop)

## Initial Goal (Accomplished)

Create a mod for the PC port where multiple people can play together online.

Unlike previous multiplayer projects, this one synchronizes enemies and events. This allows players to interact with the same world at the same time.

Interestingly enough though, the goal of the project has slowly evolved over time from simply just making a Super Mario 64 multiplayer mod to constantly maintaining and improving the project (notably the Lua API.)

## Documentation

sm64coopdx is moddable via Lua, similar to Roblox and Garry's Mod's Lua APIs. To get started, click [here](docs/lua/lua.md) to see the Lua documentation. If you want to contribute to the repo, you can view the C documentation [here](docs/c/c.md).

## Wiki

The wiki is made using GitHub's wiki feature, you can go to the wiki tab or click [here](https://github.com/ManIsCat2/sm64coopdx/wiki).

## Community

We have an official Discord server open to the public [here](https://discord.gg/TJVKHS4).

## SteveCraft Minecraft reverse-engineering tools

This repository includes an experimental Python pipeline under [`tools/minecraft_transpiler`](tools/minecraft_transpiler/README.md). It imports Java source or a local Minecraft bytecode JAR (using a user-supplied CFR decompiler), builds a language-neutral intermediate representation, and conservatively generates SM64CoopDX Lua modules or native C helpers.

The pipeline also extracts every reported block ID, state ID, property, and allowed value from Mojang's version-specific `reports/blocks.json`. For Minecraft 26.3, it generates compact Lua state lookups and an index of redstone-related candidates, so individual block-state combinations do not need to be authored manually. Redstone update logic still has to be reverse-engineered from Java code and adapted to SM64CoopDX.

The pipeline is **alpha tooling, not a complete Minecraft port**. Unsupported Java constructs and unknown Minecraft APIs are reported instead of being silently approximated. Lua output still needs an explicit SM64CoopDX gameplay adapter and runtime parity tests. Local Minecraft server/client JARs and CFR binaries are not committed to this public repository.

Run **Actions → Generate Minecraft Block State Catalog** to build the catalog. The workflow downloads the official server JAR to a temporary runner, verifies its SHA-1, runs Mojang's data generator, and uploads the results as a workflow artifact. The default target is Minecraft 26.3.

For manual imports, install the Python requirements and run:

```sh
python -m pip install -r tools/minecraft_transpiler/requirements.txt
python tools/minecraft_transpiler/import_minecraft.py \
  --input /path/to/minecraft-client.jar \
  --cfr-jar /path/to/cfr.jar \
  --block-report /path/to/generated/reports/blocks.json \
  --minecraft-version 26.3 \
  --out build/stevecraft-26.3 \
  --target lua
```


## SteveCraft independent player and invisible Mario proxy (alpha)

The `stevecraft_player_proxy` runtime is the first native bridge for the independent-player architecture:

- Steve's controller/transpiled Lua owns the authoritative Minecraft position, velocity, yaw, pitch, grounded flag, and crouching flag.
- The local `MarioState` is retained as an invisible SM64CoopDX player proxy. It receives Steve's transform and a configurable hitbox so existing engine actors can still detect a local player.
- The proxy's movement-stick magnitude is suppressed; physical movement is not delegated to Mario. Controller input remains readable by Steve's Lua logic.
- The engine update is sampled for action, action argument/timer, health, damage counter, floor contact, interaction, and riding feedback. That feedback is available to the transpiled controller.
- Proxy mode is disabled by default. Turning it off restores the Mario object's original visibility and hitbox dimensions.

The Lua bridge accepts Minecraft units: positions in blocks, velocity in blocks per game tick, angles in degrees, and hitbox dimensions in blocks. The current conversion is `160 / 1.8` SM64 world units per block, with the same origin and axis directions. World-origin offsets, multiplayer ownership, Steve mesh rendering, Minecraft AABB block collision, moving-platform transfer, damage/action translation, and complete engine-object compatibility are not implemented yet.

A Java bridge fixture and mapping are provided at `tools/minecraft_transpiler/examples/stevecraft_bridge` and `tools/minecraft_transpiler/mappings/stevecraft_bridge.json`. Generate its Lua module with:

```sh
python tools/minecraft_transpiler/mc2sm64.py \
  --input tools/minecraft_transpiler/examples/stevecraft_bridge \
  --mapping tools/minecraft_transpiler/mappings/stevecraft_bridge.json \
  --out build/stevecraft-bridge \
  --target lua \
  --strict
```

This fixture validates that Java bridge calls can be transpiled to the native Lua bindings; it is **not** a transpilation of Minecraft's actual movement or collision implementation. Real Minecraft classes still need the IR support for fields, constructors, object state, vectors/AABBs, inheritance, and their engine dependencies before they can be ported faithfully. The generated module must be loaded and called by the SteveCraft Lua mod on the player update hook; the native bridge does not automatically invent or load a Minecraft controller.
