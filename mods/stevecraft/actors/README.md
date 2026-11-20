# Steve DynOS actor

The classic Steve actor is generated from the Mojang humanoid geometry JSON and
the official 64x64 Steve skin retained in source/.

Run:

    python3 tools/generate_dynos_actor.py

This writes the DynOS sources into actors/steve/. The package workflow runs
the same generator before creating the mod ZIP. When SM64CoopDX loads the mod,
its DynOS mod-pack path converts texture.inc.c, model.inc.c and geo.inc.c into
the steve_geo actor binary.

The base and outer skin layers are split between opaque and alpha GeoLayout
layers. Head, arms and legs remain separate animated GeoLayout parts. Custom
animation clips are not part of this initial model import.
