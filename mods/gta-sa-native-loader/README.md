# GTA SA Native DFF + IFP Test (alpha)

This test mod checks the Android RenderWare loader using the original GTA San Andreas player model and pedestrian animation archive. It reads files directly from IMG v2 archives; it does not extract or convert them.

## 1. Prepare the files on Android

Create this folder structure in the external files directory belonging to SM64CoopDX:

```text
Android/data/com.maniscat2.sm64coopdx/files/GTA_SA/
├── models/
│   └── player.img
└── anim/
    └── anim.img
```

Use your own legally obtained GTA San Andreas files. The mod expects:

- `player.dff` and `player.txd` inside `models/player.img`
- `ped.ifp` inside `anim/anim.img`

Do not extract the entries and do not rename them. The IMG archives are read in place.

## 2. Run the test

Enable **GTA SA Native DFF + IFP Test** in SM64CoopDX and start a level.

The mod attempts to:

1. Scan `player.img`.
2. Read `player.dff` and its `player.txd`.
3. Parse `ped.ifp` from `anim.img`.
4. Select an animation whose name contains `IDLE`; if none exists, use the first decoded clip as a playback smoke test.
5. Spawn the DFF model near the local player and advance the selected IFP clip.

Diagnostic messages are prefixed with `[GTA SA TEST]` and are written to the game console/log.

## 3. What this test does not prove

A successful APK build only proves that the native code compiles and packages. Runtime loading and animation playback still need to be checked in-game with the original archives.

Current limitations:

- TXD dictionaries are parsed, but their textures are not yet bound to the generated SM64 display lists.
- DFF formats that use unsupported native geometry data may not render.
- IFP tracks are mapped using HAnim IDs and canonical GTA SA bone tags; order-based fallback is only approximate.
- This test does not load GTA SA collision, IDE/IPL maps, or GTA gameplay systems.

The repository intentionally does not include Rockstar game archives or extracted copyrighted model/animation files.
