# mc2sm64 — Minecraft Java source transpiler (alpha)

`mc2sm64` is the source-to-source compiler inside SteveCraft's reverse-engineering pipeline. `import_minecraft.py` accepts Java source directories/files/source JARs and can invoke a user-supplied CFR decompiler for a local bytecode JAR. The compiler parses Java with Tree-sitter, writes language-neutral IR JSON, and emits a conservative subset to SM64CoopDX Lua modules and native C helper functions.

## Important boundary

This is **not** a full Minecraft port and does not promise exact conversion of arbitrary Minecraft code. Minecraft's client/server engine depends on a large Java runtime, game registries, rendering, networking, assets, data-driven systems, and version-specific mappings. A syntactic translation alone cannot reproduce those dependencies.

The transpiler therefore uses an explicit, fail-closed policy:
- A method is emitted only when every statement/expression in its body belongs to the supported subset.
- Unknown Java API calls and unsupported syntax produce diagnostics; the method is skipped rather than silently approximated.
- Class fields and object state are reported but not emitted.
- Lua output is a pure module. Mapping it to actual SM64CoopDX hooks, player state, collisions, objects, and network sync is a separate adapter layer.
- C output contains only static methods using primitive Java types. It must be integrated into the engine and rebuilt; it is not a runtime Lua mod.
- A normal `.jar` contains bytecode (`.class`), not source. This tool accepts `.java` files, source directories, and source JAR/ZIP files containing `.java`.

## Requirements

Python 3.10+.

```sh
python -m pip install -r tools/minecraft_transpiler/requirements.txt
```

## Import Minecraft source from a local JAR

A normal Minecraft client JAR contains `.class` bytecode, not `.java` source. To inspect that code, obtain the exact-version JAR through your own legitimate Minecraft installation and provide a local CFR decompiler JAR. The importer does not download the game, authenticate to Microsoft, or redistribute the input.

```sh
python tools/minecraft_transpiler/import_minecraft.py \
  --input /path/to/minecraft-client.jar \
  --cfr-jar /path/to/cfr.jar \
  --include-package net.minecraft.world.entity \
  --include-package net.minecraft.world.phys \
  --out build/minecraft-physics \
  --target lua
```

For Java source already available (including a source JAR), omit `--cfr-jar`:

```sh
python tools/minecraft_transpiler/import_minecraft.py \
  --input /path/to/mapped-java-sources \
  --out build/minecraft-source \
  --target both
```

The importer writes `import_report.json` with source inventory, SHA-256 hashes, package filters, whether CFR was used, and the transpilation report. Use `--max-sources` to cap imported files. Repeat `--include-package` to select multiple package prefixes.

**CFR is a decompiler, not the original source.** It reconstructs approximate Java from bytecode. It cannot recover original comments, formatting, or every source-level construct. Decompiled output must be checked against the target Minecraft version and mappings.

On Android, this can run in Termux with Python, a Java runtime, the Python requirements, and a CFR JAR stored locally. It can also run in GitHub Actions when the JARs are supplied through a secure, user-controlled input workflow; do not commit Minecraft client JARs or CFR binaries to this public repository.

## Run from the repository root
```sh
python tools/minecraft_transpiler/mc2sm64.py \
  --input tools/minecraft_transpiler/examples/java \
  --out build/mc2sm64 \
  --target both
```

For actual imported source, replace `--input` with a directory of mapped/decompiled `.java` files or a source archive containing them.

Targets:
- `--target lua`: generate pure Lua modules for SM64CoopDX mods.
- `--target c`: generate C headers and source for primitive-only static helpers.
- `--target both`: generate both outputs.

Add `--strict` to return a non-zero status when any source construct or method is unsupported.

## Output

```text
build/mc2sm64/
  ir/             # parsed class and method representation
  lua/            # Lua modules; not yet registered to game hooks
  c/              # static C helper functions
  diagnostics.json # unsupported syntax, API calls, and class state
  manifest.json    # counts, output list, known limitations
```

## Currently supported Java subset

- Primitive parameters and return types.
- Local primitive variables.
- `return`, assignment, `if/else`, `while`, `break`, and `continue`.
- Numeric/boolean/string literals.
- Arithmetic, comparison and logical expressions.
- Explicit mappings for selected `Math`, `Mth`, and `MathHelper` methods.

## Not yet supported

- Arbitrary Minecraft APIs, class fields/state, constructors, inheritance, object allocation, generics, arrays, enhanced/ordinary `for`, `switch`, exceptions, lambdas, method references, annotations with runtime semantics, and full Java standard-library behavior.
- Automatic bytecode decompilation or mapping resolution.
- Automatic conversion of Minecraft's entity/component/world registries into SM64 systems.
- Automatic camera, movement, collision, inventory, block, or rendering port.

## Mapping extension

Built-in mappings live in `mappings/sm64coopdx.json`. An extra JSON file can add or override `static_methods` and `static_fields`:

```json
{
  "static_methods": {
    "Mth.clamp": {"lua": "@clamp", "c": "@clamp"}
  }
}
```

Only map a call when its semantics match exactly. Do not map a Minecraft call to a similarly named SM64 function without checking units, coordinate systems, tick rate, and side effects.

## Minecraft source handling

Use source code and mappings for the exact Minecraft version being researched. The importer does not download proprietary game code, bundle Minecraft assets, or bypass a launcher. Keep imported sources outside this repository and supply the local path to `--input`. Ensure your use complies with the applicable game license and modding rules.

## Next engineering milestones

1. Add version-specific Mojang mappings and resolve intermediary/official names before translation.
2. Extend the IR for fields, constructors, object state, vectors, and the selected entity/component model.
3. Add semantic adapters for Minecraft registries, entities, world/chunk access, and tick timing.
4. Define explicit SM64CoopDX runtime bindings for MarioState, camera, collision surfaces, objects, and networking.
5. Port one isolated system at a time and compare it against reference behavior in Minecraft.
6. Add generated-code, runtime, and in-game parity tests before calling a subsystem ported.
