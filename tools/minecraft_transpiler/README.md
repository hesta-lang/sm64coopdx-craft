# mc2sm64 — Minecraft Java source importer and transpiler (alpha)

`mc2sm64` is the source-to-source compiler inside SteveCraft's reverse-engineering pipeline. `import_minecraft.py` accepts Java source directories/files/source JARs and can invoke a user-supplied CFR decompiler for a local bytecode JAR. The compiler parses Java with Tree-sitter, writes language-neutral IR JSON, and emits a conservative subset to SM64CoopDX Lua modules and native C helper functions.

## Important boundary

This is **not** a full Minecraft port. Minecraft's engine depends on a large Java runtime, game registries, rendering, networking, assets, data-driven systems, and version-specific mappings. A syntactic translation alone cannot reproduce those dependencies.

The transpiler uses a fail-closed policy:
- A method is emitted only when every statement/expression belongs to the supported subset.
- Unknown Java API calls and unsupported syntax produce diagnostics; the method is skipped instead of silently approximated.
- Class fields and object state are reported but not emitted.
- Lua output is a pure module. SM64CoopDX hooks, player state, collisions, objects, and network sync need a separate adapter.
- C output contains only primitive-only static helpers; it requires an engine rebuild.
- A normal `.jar` contains bytecode (`.class`), not source. CFR reconstructs approximate source; it cannot recover comments or all original constructs.

## Requirements

Python 3.10+.

```sh
python -m pip install -r tools/minecraft_transpiler/requirements.txt
```

## Import Java source or decompile a local JAR

The importer does not download Minecraft or commit game files. Supply local Java sources or a local bytecode JAR and CFR:

```sh
python tools/minecraft_transpiler/import_minecraft.py \\
  --input /path/to/minecraft-client.jar \\
  --cfr-jar /path/to/cfr.jar \\
  --include-package net.minecraft.world.entity \\
  --out build/minecraft-26.3 \\
  --target lua
```

## Automatic block-state and redstone-state catalog (26.3)

Do **not** author every block or state manually. Minecraft's own data generator writes `reports/blocks.json`. The 26.3 report records each namespaced block ID, its state-property domains, the exact state IDs and property combinations, and the default state marker. The report is an inventory of states, not the implementation of block behavior or redstone tick/update logic.

The extractor creates:
- `block_states.json`: complete block/property/state inventory, with a SHA-256 hash of the source report.
- `block_states.lua`: compact Lua state-ID lookup tables and `get_properties(block_id, state_id)`.
- `redstone_blocks.json`: candidate redstone-related blocks and their state data.
- `redstone_candidates.lua`: compact Lua index of those candidates.
- `extract_report.json`: version and item counts.

Redstone candidates are detected from known component IDs and state-property names such as `powered` and `power`. This is a discovery index, not a proof that every candidate shares the same behavior. Java code still has to be analyzed to reproduce signal propagation, neighbor notifications, and scheduled ticks.

### Recommended: generate the catalog from GitHub Actions

Open **Actions → Generate Minecraft Block State Catalog → Run workflow**. The default is `26.3`. The workflow:
1. Resolves the exact version through Mojang's official version manifest.
2. Downloads the official server JAR into the temporary runner and verifies its SHA-1.
3. Runs Mojang's data generator with Java 25.
4. Extracts the complete block-state catalog and validates both Lua modules.
5. Uploads the catalog as a workflow artifact. It does not commit the server JAR or generated game files.

### Run locally

Minecraft 26.3 requires Java 25. Run:

```sh
python tools/minecraft_transpiler/download_server_jar.py \\
  --version 26.3 \\
  --out /tmp/minecraft-server-26.3.jar

java -DbundlerMainClass=net.minecraft.data.Main \\
  -jar /tmp/minecraft-server-26.3.jar \\
  --reports --server --all \\
  --output /tmp/minecraft-26.3-generated

python tools/minecraft_transpiler/extract_block_states.py \\
  --input /tmp/minecraft-26.3-generated/reports/blocks.json \\
  --out build/minecraft-26.3-blocks \\
  --minecraft-version 26.3
```

### Attach the catalog to the Java importer

```sh
python tools/minecraft_transpiler/import_minecraft.py \\
  --input /path/to/decompiled-minecraft-sources \\
  --block-report /path/to/generated/reports/blocks.json \\
  --minecraft-version 26.3 \\
  --out build/stevecraft-26.3 \\
  --target lua
```

This writes translated Java output to `generated/`, the block-state catalogs to `block_states/`, and both reports to `import_report.json`.

## Current Java subset

- Primitive parameters and return types; local primitive variables.
- `return`, assignment, `if/else`, `while`, `break`, and `continue`.
- Numeric/boolean/string literals.
- Arithmetic, comparison, and logical expressions.
- Explicit mappings for selected `Math`, `Mth`, and `MathHelper` methods.

## Not yet supported

- Arbitrary Minecraft APIs, fields/state, constructors, inheritance, object allocation, generics, arrays, `for`, `switch`, exceptions, lambdas, method references, and full Java standard-library behavior.
- Automatic conversion of redstone update algorithms, neighbor notifications, scheduled ticks, signal propagation, block entities, or world/chunk storage into SM64CoopDX runtime behavior.
- Automatic camera, movement, collision, inventory, block rendering, or full gameplay port.

## Mapping extension

Built-in mappings live in `mappings/sm64coopdx.json`. An extra JSON file can add or override `static_methods` and `static_fields`:

```json
{
  "static_methods": {
    "Mth.clamp": {"lua": "@clamp", "c": "@clamp"}
  }
}
```

Only map a call when its semantics match exactly. Check units, coordinate systems, tick rate, and side effects.

## Next engineering milestones

1. Resolve official mappings and pin the exact 26.3 source/data version.
2. Extend the IR for fields, constructors, object state, vectors, and selected block/entity classes.
3. Reverse-engineer block behavior and redstone logic from Java classes, using the extracted catalog to avoid manually enumerating state variants.
4. Add adapters for registries, world/chunk access, scheduled ticks, neighbor updates, signal propagation, and tick timing.
5. Define SM64CoopDX runtime bindings for MarioState, camera, collision surfaces, objects, and networking.
6. Port one isolated system at a time and compare it against Minecraft reference behavior.
