# Steve DynOS actor assets

This directory must contain the converted Steve actor when the model pipeline
is ready.

Expected entry asset:

- `steve_geo.bin` — DynOS GeoLayout/model binary referenced by
  `smlua_model_util_get_id("steve_geo")`.

The binary must reference its converted texture and animation data in the
format supported by the SM64CoopDX DynOS loader. Do not replace this with a
placeholder cube model: the goal is to import the Minecraft player geometry,
UV layout and skin accurately.
