# SteveCraft animation tests

Runs the exact pure animation generator in mods/stevecraft/main.lua under Lua
5.4 with a test-only export hook. It validates the 24-frame channel/value
tables, all 63 index pairs, signed 16-bit value bounds, zero root-translation
placeholders for ANIM_FLAG_6, neutral/quarter/opposite phases, and opposing
left/right arm and leg swings.

This validates generated data structure and formulas; it does not prove how
the animation looks on an Android device. In-game rendering still needs a
device test after CI passes.
