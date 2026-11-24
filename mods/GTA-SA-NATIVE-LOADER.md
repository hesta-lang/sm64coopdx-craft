# GTA SA Native Loader — standalone mod

The Android APK includes this as a **single-file Lua mod**, listed in the in-game Mods menu as **GTA SA Native Loader**. The native DFF/IFP reader is compiled into the APK; the Lua file is the independently enabled mod.

## Required game files

Place your legally obtained compatible GTA San Andreas IMG archives here:

```
Android/data/com.maniscat2.sm64coopdx/files/GTA_SA/
├── models/player.img
└── anim/anim.img
```

The current test expects `player.dff` and `player.txd` inside `player.img`, and `ped.ifp` inside `anim.img`.

Enable **GTA SA Native Loader** in the Mods menu and start a level. Check the game log for lines beginning with `[GTA SA]`.

## Important limitations

- The APK build verifies that the mod file is embedded in the package; it does not prove that the DFF/IFP parser works with every GTA SA release.
- TXD textures are parsed but are not yet bound to the generated display lists.
- Native geometry variants may not render.
- Animation retargeting and playback still require in-game validation with the user's actual archives.
