# GTA San Andreas Native Assets (alpha)

This built-in test mod reads original GTA San Andreas assets directly from an IMG v2 archive. It does not extract or convert them.

## Files expected on Android

Copy the original files from your own GTA San Andreas installation to:

- \`/storage/emulated/0/GTA_SA/models/player.img\`
- \`/storage/emulated/0/GTA_SA/anim/anim.img\`

The test mod looks for:

- \`player.dff\` and \`player.txd\` inside \`player.img\`
- \`ped.ifp\` inside \`anim.img\`

Edit the two path constants at the top of \`main.lua\` if the files are stored elsewhere.

## Native Lua API

- \`gta_sa_scan_img(path)\`: reads and lists IMG v2 entries (first 128 names in the result).
- \`gta_sa_load_dff(imgPath, dffEntry, scale[, txdImgPath, txdEntry])\`: reads the DFF/TXD from IMG, parses RenderWare, converts available triangle geometry into a DynOS model and returns its model ID plus counts.
- \`gta_sa_load_ifp(imgPath, ifpEntry)\`: reads and validates ANP3/ANPK IFP structures and returns animation/track/frame metadata.

## Current alpha limits

This is a first runtime integration, not full GTA runtime compatibility:
- IMG v2, DFF RenderWare chunks, D3D8 native vertex/index buffers, TXD dictionaries and IFP ANP3/ANPK metadata are read in the engine.
- The generated preview model uses vertex/material colors. Texture dictionary decoding is wired into librw, but the SM64 display-list conversion does not yet bind GTA TXD texture maps.
- DFF skeletal skin weights and IFP tracks are not yet connected to per-frame bone skinning. The preview character is static.
- GTA collision, IDE/IPL world streaming, and GTA gameplay systems are not included.

The model and texture archives are copyrighted game data and are intentionally not included in this repository. The user must provide files from their own game installation.
