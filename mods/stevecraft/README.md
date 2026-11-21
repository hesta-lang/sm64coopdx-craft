# SteveCraft — proxy-driven Steve (alpha)

SteveCraft is a standalone SM64CoopDX mod. It does not patch the Android APK
or add native code to the game executable.

## Player architecture

- Place the supplied original DynOS binary at
  `mods/stevecraft/actors/steve_geo.bin`, unchanged.
- Its internal GeoLayout is named `mario_geo`; DynOS registers the custom actor
  by the binary filename, `steve_geo`. Lua therefore requests
  `smlua_model_util_get_id("steve_geo")`.
- Lua assigns that model to the existing `m.marioObj` with
  `obj_set_model_extended`. It does not spawn another Steve object or hide Mario.
- The same Mario object remains the engine proxy for collision, actions, damage,
  platforms and networking. SteveState retains authority over position and
  velocity during ground/air physics steps, mirroring its transform to
  MarioState and the same object.
- SM64's action and animation timeline stays attached to that player object.
  The binary uses a Mario-style GeoLayout hierarchy; its animation compatibility
  still needs in-game validation.

## Binary-only asset pipeline

The actor directory is intentionally binary-only: `steve_geo.bin` is the sole
file. The package no longer creates or includes actor source folders,
`geo.inc.c`, `geo.h`, `geo_header.h`, `model.inc.c`, generated textures,
or a Python model generator.

The earlier `CUSTOM_CMD` errors are consistent with DynOS parsing the generated
`geo.inc.c` source during pack generation. Removing those generated source
folders and loading the supplied compiled binary directly avoids that source
parser path; no commands are stripped from the binary.

## Remaining validation

- The Steve ground/air controller is experimental; water, ceilings, ladders,
  knockback, riding and special movement still need in-game validation.
- The actor's visual scale and Mario-animation compatibility need testing on
  the Android build.
- CI checks the binary signature, Lua syntax and package contents. It cannot
  certify the in-game rendering result.
