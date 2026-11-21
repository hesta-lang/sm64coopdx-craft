# SteveCraft GeoLayout read-only rig audit

This parser is an inspection/CI tool only. It never writes to or rebuilds the
actor binary. It checks the DYNOSBIN header, zlib payload size, original SHA-256,
DynOS GeoLayout record, embedded pointer references, command widths, and
GEO_OPEN_NODE/GEO_CLOSE_NODE balance.

The original actor binary has SHA-256:

    773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1

The current mario_geo record has 361 GeoLayout words and 215 commands. The
verified hierarchy contains 20 GEO_ANIMATED_PART nodes and no custom DynOS
GEO_BONE nodes. The animated layout references separate torso, forearm and leg
display lists; the head is a separate GEO_DISPLAY_LIST node in its subtree.
This establishes a Mario-style articulated GeoLayout, not a six-independent-
cuboid rig.

A GEO_ANIMATED_PART count alone does not prove animation channel order or that
every part is an independently exposed bone in Lua. The next animation stage
must validate the 20-part channel mapping and actual engine animation format
before any animation is attached to m.marioObj.

Run:

    python tools/stevecraft_rig_audit/inspect_geo.py       --binary mods/stevecraft/actors/minecraft_steve_geo.bin       --layout mario_geo       --output build/stevecraft-rig-audit.json
