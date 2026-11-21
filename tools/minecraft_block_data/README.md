# SteveCraft Minecraft Java block metadata pipeline

Reference release: **Minecraft Java 26.3**.

This tool creates a normalized resource index from the official client JAR. It
does not transpile Minecraft classes or claim to dump the complete Java block
registry.

## Extracted resource metadata

- Blockstate selectors and multipart model applications.
- Referenced block-model IDs, parent links, texture-slot references, cuboid
  bounds, and face texture-slot references.
- Block tag membership.
- Recipe IDs, recipe types, ingredient item IDs, and result item/count.
- Whether a block has a block loot-table resource.
- Sound-event IDs and the number of sound entries.

Textures, audio files, raw Minecraft JSON resources, and Minecraft source code
are not copied.

## Values that are not guessed

Destroy speed, explosion resistance, friction, collision and occlusion shapes,
fluid state, light emission, and redstone behavior are Java registry/runtime
properties. These fields stay null and are marked requires_java_runtime until
a separately validated Java runtime adapter can resolve them.

coverage.registry_complete is always false. A client JAR's blockstate resource
directory is not a complete inventory of registered blocks. A later Java
registry inspection phase must provide all block IDs and property domains.

## Run locally

    python tools/minecraft_block_data/extract.py --version 26.3 --output build/minecraft-26.3-block-data.json

Pass --jar PATH to use an existing client JAR instead of downloading it.

## Validation

The SteveCraft Research Pipeline workflow runs unit tests, validates output
against block-data.schema.json, downloads the selected official client JAR,
verifies its Mojang-published SHA-1, extracts the normalized index, and uploads
the resulting JSON as a short-lived Actions artifact. It does not alter the
standalone mod ZIP or the SM64CoopDX APK.

## Licensing and distribution

The client JAR is used only in the temporary CI runner. The workflow does not
commit or redistribute Mojang's JAR, source, textures, or audio. Generated
metadata is for engineering/research; do not bundle it in a public mod release
until its compatibility and distribution status have been reviewed against
Minecraft's current usage rules.
