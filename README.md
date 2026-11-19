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

The pipeline is **alpha tooling, not a complete Minecraft port**. Unsupported Java constructs and unknown Minecraft APIs are reported instead of being silently approximated. Lua output still needs an explicit SM64CoopDX gameplay adapter and runtime parity tests. A local Minecraft JAR and CFR binary must not be committed to this public repository.

Run the importer from the repository root:

```sh
python -m pip install -r tools/minecraft_transpiler/requirements.txt
python tools/minecraft_transpiler/import_minecraft.py \
  --input /path/to/minecraft-client.jar \
  --cfr-jar /path/to/cfr.jar \
  --include-package net.minecraft.world.entity \
  --out build/stevecraft-import \
  --target lua
```

