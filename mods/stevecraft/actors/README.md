# Steve actor binary

Upload the original `minecraft_steve_geo.bin` here with the exact filename:

```
steve_geo.bin
```

Keep the binary unchanged. Do not add `geo.inc.c`, `model.inc.c`,
`geo.h`, `geo_header.h`, generated source folders, or a Python generator.
The packaging workflow includes only `steve_geo.bin`; this README is not
included in the game mod.

The old `CUSTOM_CMD` errors came from DynOS parsing generated actor source.
The binary-only package bypasses that source-generation path.
