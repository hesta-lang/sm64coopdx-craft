#!/usr/bin/env python3
"""Build exact block-state JSON/Lua catalogs from Mojang reports/blocks.json."""
from __future__ import annotations
import argparse, hashlib, json, re, sys
from pathlib import Path
from typing import Any

ID_RE = re.compile(r"^[a-z0-9_.-]+:[a-z0-9/._-]+$")
KNOWN = {"redstone_wire", "repeater", "comparator", "redstone_torch", "redstone_wall_torch", "lever", "observer", "piston", "sticky_piston", "piston_head", "dispenser", "dropper", "hopper", "target", "tnt", "daylight_detector", "tripwire", "tripwire_hook", "lightning_rod", "sculk_sensor", "calibrated_sculk_sensor", "note_block", "crafter", "bell"}
HINTS = {"powered", "power", "signal", "signal_strength", "lit", "triggered", "extended", "conditional", "locked", "disarmed", "short"}
NAME_HINTS = ("redstone", "repeater", "comparator", "piston", "button", "pressure_plate", "daylight_detector", "tripwire", "sculk_sensor", "lightning_rod", "target", "crafter")


def text_value(value: Any) -> str:
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, (str, int, float)): return str(value)
    raise ValueError("Block-state values must be strings or scalar numbers")


def block_entry(block_id: str, raw: Any) -> dict[str, Any]:
    if not ID_RE.fullmatch(block_id) or not isinstance(raw, dict):
        raise ValueError(f"Invalid block entry: {block_id!r}")
    declared = raw.get("properties") or {}
    if not isinstance(declared, dict): raise ValueError(f"{block_id}: properties must be an object")
    domains = {}
    for name, values in sorted(declared.items()):
        if not isinstance(name, str) or not isinstance(values, list) or not values:
            raise ValueError(f"{block_id}: invalid property domain {name!r}")
        values = [text_value(x) for x in values]
        if len(set(values)) != len(values): raise ValueError(f"{block_id}.{name}: duplicate values")
        domains[name] = values
    raw_states = raw.get("states", [])
    if not isinstance(raw_states, list): raise ValueError(f"{block_id}: states must be an array")
    states, ids, defaults, inferred = [], set(), [], {}
    for state in raw_states:
        if not isinstance(state, dict): raise ValueError(f"{block_id}: malformed state")
        sid = state.get("id")
        if isinstance(sid, bool) or not isinstance(sid, int) or sid < 0 or sid in ids:
            raise ValueError(f"{block_id}: invalid or duplicate state ID {sid!r}")
        ids.add(sid)
        props = state.get("properties") or {}
        if not isinstance(props, dict): raise ValueError(f"{block_id} state {sid}: invalid properties")
        props = {k: text_value(v) for k, v in sorted(props.items())}
        for key, value in props.items():
            inferred.setdefault(key, [])
            if value not in inferred[key]: inferred[key].append(value)
        if state.get("default") is True: defaults.append(sid)
        states.append({"id": sid, "properties": props, **({"default": True} if sid in defaults else {})})
    if len(defaults) > 1: raise ValueError(f"{block_id}: multiple default states")
    if not domains: domains = inferred
    else:
        for key, vals in inferred.items():
            if key not in domains or not set(vals).issubset(domains[key]):
                raise ValueError(f"{block_id}.{key}: state contains an undeclared property value")
    for state in states:
        if set(state["properties"]) != set(domains):
            raise ValueError(f"{block_id} state {state['id']}: state/property fields do not match")
    result = {"properties": domains, "states": states}
    if defaults: result["default_state_id"] = defaults[0]
    return result


def q(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'


def write_lua(path: Path, version: str, blocks: dict, candidates: dict) -> None:
    out = ["-- Generated from Mojang reports/blocks.json.", "local M = {", f"  version = {q(version)},", "  blocks = {"]
    for bid, block in sorted(blocks.items()):
        names = sorted(block["properties"])
        out += [f"    [{q(bid)}] = {{", f"      default_state_id = {block.get('default_state_id', 'nil')},", "      property_names = {" + ", ".join(q(x) for x in names) + "},", "      property_values = {"]
        for name in names: out.append("        {" + ", ".join(q(x) for x in block["properties"][name]) + "},")
        out += ["      },", "      states = {"]
        for state in block["states"]:
            indexes = [str(block["properties"][name].index(state["properties"][name]) + 1) for name in names]
            out.append(f"        [{state['id']}] = {{{', '.join(indexes)}}},")
        out += ["      },", "    },"]
    out += ["  },", "}", "", "function M.get_properties(block_id, state_id)", "  local b = M.blocks[block_id]", "  if not b then return nil end", "  local indexes = b.states[state_id]", "  if not indexes then return nil end", "  local result = {}", "  for i, name in ipairs(b.property_names) do result[name] = b.property_values[i][indexes[i]] end", "  return result", "end", "", "return M", ""]
    path.write_text("\n".join(out), encoding="utf-8")
    red = ["-- Generated redstone candidate index; state data is in block_states.lua.", "return {", f"  version = {q(version)},", "  blocks = {"]
    for bid, item in sorted(candidates.items()):
        reasons = ", ".join(q(x) for x in item["reasons"])
        red.append(f"    [{q(bid)}] = {{confidence = {q(item['confidence'])}, reasons = {{{reasons}}}}},")
    red += ["  },", "}", ""]
    path.with_name("redstone_candidates.lua").write_text("\n".join(red), encoding="utf-8")


def extract_block_states(source: Path, output: Path, version: str = "26.3") -> dict:
    if source.is_dir():
        choices = [source / "reports/blocks.json", source / "blocks.json"]
        source = next((p for p in choices if p.is_file()), choices[0])
    if not source.is_file(): raise FileNotFoundError(f"blocks.json not found: {source}")
    payload = json.loads(source.read_text(encoding="utf-8"))
    raw_blocks = payload.get("blocks", payload) if isinstance(payload, dict) else None
    if not isinstance(raw_blocks, dict) or not raw_blocks: raise ValueError("blocks.json must be a non-empty object")
    blocks, candidates, state_ids = {}, {}, {}
    for bid, raw in sorted(raw_blocks.items()):
        block = block_entry(bid, raw)
        for state in block["states"]:
            sid = state["id"]
            if sid in state_ids: raise ValueError(f"State ID {sid} duplicated by {state_ids[sid]} and {bid}")
            state_ids[sid] = bid
        blocks[bid] = block
        path = bid.split(":", 1)[1]
        reasons = []
        if path in KNOWN: reasons.append("known_redstone_component")
        if any(h in path for h in NAME_HINTS): reasons.append("block_name_match")
        reasons += [f"state_property:{p}" for p in sorted(set(block["properties"]) & HINTS)]
        if reasons:
            high = any(x in {"known_redstone_component", "state_property:powered", "state_property:power", "state_property:signal", "state_property:signal_strength"} for x in reasons)
            candidates[bid] = {"confidence": "high" if high else "possible", "reasons": list(dict.fromkeys(reasons)), **block}
    output.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    catalog = {"schema_version": 1, "minecraft_version": version, "source_report": source.name, "source_report_sha256": digest, "block_count": len(blocks), "state_count": len(state_ids), "blocks": blocks}
    redstone = {"schema_version": 1, "minecraft_version": version, "candidate_count": len(candidates), "note": "Name/property-based candidates only; behavior still requires Java-code analysis.", "blocks": candidates}
    (output / "block_states.json").write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (output / "redstone_blocks.json").write_text(json.dumps(redstone, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    write_lua(output / "block_states.lua", version, blocks, candidates)
    summary = {"minecraft_version": version, "source_report": str(source), "source_report_sha256": digest, "block_count": len(blocks), "state_count": len(state_ids), "redstone_candidate_count": len(candidates)}
    (output / "extract_report.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract exact Minecraft block states and redstone candidates")
    parser.add_argument("--input", required=True, type=Path, help="blocks.json or its containing directory")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--minecraft-version", default="26.3")
    args = parser.parse_args()
    try: result = extract_block_states(args.input, args.out, args.minecraft_version)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"block-state-extractor: error: {exc}", file=sys.stderr); return 1
    print(json.dumps({"status": "extracted", **result}, indent=2)); return 0

if __name__ == "__main__": raise SystemExit(main())
