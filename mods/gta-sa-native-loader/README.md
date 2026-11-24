# GTA San Andreas Native Assets (alpha)

This test mod reads original GTA San Andreas assets directly from IMG v2 archives. It does not extract or convert them.

## Android files

Copy the original files from your own GTA San Andreas installation to:

- `/storage/emulated/0/GTA_SA/models/player.img`
- `/storage/emulated/0/GTA_SA/anim/anim.img`

The mod reads `player.dff` and `player.txd` from `player.img`, and `ped.ifp` from `anim.img`. Change the path constants at the top of `main.lua` when needed.

## Lua API

- `gta_sa_scan_img(path)`: reads IMG v2 entries.
- `gta_sa_load_dff(imgPath, dffEntry, scale[, txdImgPath, txdEntry])`: loads a DFF and returns its DynOS model ID and mesh/bone counts.
- `gta_sa_load_ifp(imgPath, ifpEntry[, modelId])`: decodes ANP3/ANPK keyframes. Supplying modelId attaches the clips to that DFF.
- `gta_sa_play_ifp(modelId, animationName)`: starts a clip and automatically retargets its tracks to the DFF HAnim hierarchy.
- `gta_sa_update_ifp(modelId, deltaSeconds)`: advances and applies the active clip.

## Current alpha limits

- DFF skin weights are evaluated on the CPU using inverse-bind matrices and live HAnim frames; DynOS vertex buffers are updated dynamically.
- IFP tracks are resolved by RenderWare HAnim bone ID. When an ANP3 track stores `bone_id = -1`, its canonical GTA SA bone name is converted to the corresponding HAnim tag before matching. Only tracks still unresolved after semantic matching use an order-based fallback; unmapped target bones remain in their rest pose.
- The GTA SA canonical tags make the standard pedestrian skeleton independent of frame order or cosmetic bone-name spacing/case. A completely unrelated rig with different anatomy and no matching semantic tags cannot be perfectly retargeted automatically; the order fallback is only a best-effort approximation.
- GTA TXD textures are parsed by RenderWare but are not yet bound to the generated SM64 display lists.
- GTA collision, IDE/IPL world streaming, and GTA gameplay systems are not included.

Game archives and models are copyrighted data and are intentionally not included. The user must supply files from their own game installation.
