# SteveCraft 0.2.1-alpha — standalone visual validation

SteveCraft is an independent Lua mod for SM64CoopDX. It does not modify or repackage the Android APK.

## Current validation strategy

- The original binary is kept unchanged at `actors/minecraft_steve_geo.bin`.
- Its internal GeoLayout symbol is `mario_geo`; Lua looks up that internal symbol through `smlua_model_util_get_id("mario_geo")`.
- The model is assigned to the existing `m.marioObj`; no second player object is spawned.
- This diagnostic build intentionally leaves Mario's native physics untouched. The experimental custom physics hook is disabled because it displaced the player proxy before the model was confirmed.
- After the model is visible and its scale/origin are verified, Steve's independent movement controller can be reintroduced in isolated stages.

## Important

CI verifies the DynOS binary signature, Lua syntax and ZIP contents only. A successful package does not prove that the Android runtime can parse or render the actor. The in-game log messages distinguish GeoLayout lookup failure from model assignment failure.
