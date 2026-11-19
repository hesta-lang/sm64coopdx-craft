# mc2sm64 — Minecraft Java source transpiler (alpha)

`mc2sm64` is the first tooling layer for SteveCraft's reverse-engineering pipeline. It imports `.java` sources, parses them with Tree-sitter, writes a language-neutral IR JSON file, and emits a conservative subset to SM64CoopDX Lua modules and native C helper functions.

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

1. Add a versioned Minecraft mapping/source adapter and symbol-resolution database.
2. Extend the IR for fields, constructors, object state, vectors, and the selected entity/component model.
3. Define an explicit SM64CoopDX runtime adapter for MarioState, camera, collision surfaces, objects, and tick timing.
4. Port one isolated system at a time and compare it against reference behavior in Minecraft.
5. Add generated-code and in-game parity tests before calling a subsystem ported.
