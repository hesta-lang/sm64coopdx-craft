#!/usr/bin/env python3
"""Read-only DynOS GeoLayout audit for the original SteveCraft actor binary."""
from __future__ import annotations
import argparse
import hashlib
import json
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

MAGIC = b"DYNOSBIN"
MARIO_ANIM_PART_NAMES = [
    "ROOT", "BUTT", "TORSO", "HEAD",
    "UPPER_LEFT", "LEFT_ARM", "LEFT_FOREARM", "LEFT_HAND",
    "UPPER_RIGHT", "RIGHT_ARM", "RIGHT_FOREARM", "RIGHT_HAND",
    "LOWER_LEFT", "LEFT_THIGH", "LEFT_LEG", "LEFT_FOOT",
    "LOWER_RIGHT", "RIGHT_THIGH", "RIGHT_LEG", "RIGHT_FOOT",
]
EXPECTED_SHA256 = "773446e965b4123f032faf1948528a5b1541d4ca7b3fae9fe8220ce0769fcad1"
PNTR = 0x52544E50
FUNC = 0x434E5546
LUAV = 0x5641554C

FIXED = {
    0x00: 2, 0x01: 1, 0x02: 2, 0x03: 1, 0x04: 1, 0x05: 1,
    0x06: 1, 0x07: 1, 0x08: 3, 0x09: 1, 0x0B: 1, 0x0C: 1,
    0x0D: 2, 0x0E: 2, 0x0F: 5, 0x13: 3, 0x15: 2, 0x16: 2,
    0x17: 1, 0x18: 2, 0x19: 2, 0x1A: 2, 0x1B: 1, 0x1C: 3,
    0x1E: 2, 0x1F: 4, 0x20: 1, 0x21: 3, 0x22: 2, 0x23: 2,
}


def signed16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def read_string(data: bytes, pos: int) -> tuple[str, int]:
    if pos >= len(data):
        raise ValueError("EOF at DynOS string length")
    length = data[pos]
    pos += 1
    end = pos + length
    if end > len(data):
        raise ValueError("EOF inside DynOS string")
    return data[pos:end].decode("utf-8"), end


def word_count(word: int) -> int:
    op, params = word & 0xFF, (word >> 8) & 0xFF
    if op == 0x10:
        base = {0x00: 4, 0x10: 2, 0x20: 2, 0x30: 1}.get(params & 0x70)
        if base is None:
            raise ValueError(f"Unknown GEO_TRANSLATE_ROTATE layout 0x{params:02x}")
        return base + bool(params & 0x80)
    if op in (0x11, 0x12, 0x14):
        return 2 + bool(params & 0x80)
    if op == 0x1D:
        return (4 if params & 0x40 else 2) + bool(params & 0x80)
    if op == 0x24:
        return 8 if params & 0x80 else 5
    if op == 0x0A:
        return 3 if params & 1 else 2
    if op not in FIXED:
        raise ValueError(f"Unknown GeoLayout opcode 0x{op:02x}")
    return FIXED[op]


def load_layout(path: Path, name: str) -> tuple[list[dict], str, int]:
    raw = path.read_bytes()
    if len(raw) < 16 or raw[:8] != MAGIC:
        raise ValueError("Invalid DYNOSBIN header")
    expected_size = struct.unpack_from("<Q", raw, 8)[0]
    data = zlib.decompress(raw[16:])
    if len(data) != expected_size:
        raise ValueError("Decompressed size does not match DYNOSBIN header")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError(f"Original .bin changed: SHA-256 is {digest}")

    encoded = name.encode()
    needle = bytes((5, len(encoded))) + encoded  # DATA_TYPE_GEO_LAYOUT
    hits = []
    start = 0
    while (pos := data.find(needle, start)) >= 0:
        count_pos = pos + len(needle)
        if count_pos + 4 <= len(data):
            count = struct.unpack_from("<I", data, count_pos)[0]
            if 0 < count <= 10000:
                hits.append((count, count_pos + 4))
        start = pos + 1
    if len(hits) != 1:
        raise ValueError(f"Expected one {name!r} GeoLayout, found {len(hits)}")
    count, pos = hits[0]

    words = []
    for index in range(count):
        if pos + 4 > len(data):
            raise ValueError(f"EOF at GeoLayout word {index}")
        offset = pos
        value = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        ref = None
        if value == FUNC:
            if pos + 4 > len(data):
                raise ValueError("EOF in function reference")
            ref = {"kind": "function", "index": struct.unpack_from("<i", data, pos)[0]}
            pos += 4
        elif value in (PNTR, LUAV):
            token, pos = read_string(data, pos)
            if value == PNTR:
                if pos + 4 > len(data):
                    raise ValueError("EOF in pointer metadata")
                pointer_data = struct.unpack_from("<I", data, pos)[0]
                pos += 4
                ref = {"kind": "pointer", "name": token, "data": pointer_data}
            else:
                ref = {"kind": "lua_token", "name": token}
        words.append({"value": value, "offset": offset, "ref": ref})
    if pos != len(data):
        raise ValueError(f"GeoLayout ended at {pos}, but stream size is {len(data)}")
    return words, digest, count


def inspect(binary: Path, name: str = "mario_geo") -> dict:
    words, digest, count = load_layout(binary, name)
    animated, bone_nodes, display_lists, branches = [], [], [], []
    counts = Counter()
    depth = 0
    minimum_depth = 0
    commands = 0
    i = 0
    while i < len(words):
        first = words[i]["value"]
        op, params = first & 0xFF, (first >> 8) & 0xFF
        size = word_count(first)
        if i + size > len(words):
            raise ValueError(f"Command at {i} exceeds GeoLayout word count")
        commands += 1
        counts[op] += 1
        if op == 0x04:
            depth += 1
        elif op == 0x05:
            depth -= 1
            minimum_depth = min(minimum_depth, depth)
        elif op == 0x13:
            yz = words[i + 1]["value"]
            animated.append({
                "index": len(animated),
                "channel_name": MARIO_ANIM_PART_NAMES[len(animated)] if len(animated) < len(MARIO_ANIM_PART_NAMES) else "UNKNOWN",
                "word_index": i,
                "depth": depth,
                "translation": [
                    signed16((first >> 16) & 0xFFFF),
                    signed16(yz & 0xFFFF),
                    signed16((yz >> 16) & 0xFFFF)
                ],
                "display_list": words[i + 2]["ref"]
            })
        elif op == 0x24:
            xyzr = [words[i + k]["value"] for k in (1, 2, 3)]
            bone_nodes.append({
                "index": len(bone_nodes), "word_index": i, "depth": depth,
                "params": params,
                "translation_rotation": [
                    signed16(xyzr[0] & 0xFFFF), signed16(xyzr[0] >> 16),
                    signed16(xyzr[1] & 0xFFFF), signed16(xyzr[1] >> 16),
                    signed16(xyzr[2] & 0xFFFF), signed16(xyzr[2] >> 16)
                ],
                "scale_words": [words[k]["value"] for k in range(i + 4, i + 7)] if size == 8 else None,
                "display_list": words[i + (7 if size == 8 else 4)]["ref"]
            })
        elif op == 0x15:
            display_lists.append({
                "word_index": i, "depth": depth,
                "drawing_layer": params, "target": words[i + 1]["ref"]
            })
        elif op == 0x02:
            branches.append({
                "word_index": i, "depth": depth,
                "branch_type": params, "target": words[i + 1]["ref"]
            })
        i += size

    if depth != 0 or minimum_depth < 0 or i != len(words):
        raise ValueError("GeoLayout open/close hierarchy is unbalanced")
    return {
        "format_version": "1.0.0",
        "source": {"binary_sha256": digest, "modified": False},
        "layout": {"name": name, "word_count": count, "command_count": commands},
        "hierarchy": {
            "balanced": True,
            "animated_part_count": len(animated),
            "dynos_bone_node_count": len(bone_nodes)
        },
        "opcode_counts": {f"0x{op:02x}": amount for op, amount in sorted(counts.items())},
        "animated_parts": animated,
        "dynos_bone_nodes": bone_nodes,
        "display_lists": display_lists,
        "branch_layouts": branches
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--layout", default="mario_geo")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.binary, args.layout)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(
            f"Audited {result['layout']['name']}: {result['layout']['word_count']} words, "
            f"{result['layout']['command_count']} commands, "
            f"{result['hierarchy']['animated_part_count']} animated parts, "
            f"{result['hierarchy']['dynos_bone_node_count']} DynOS bone nodes."
        )
        print(f"Original binary SHA-256 verified: {result['source']['binary_sha256']}")
        return 0
    except (OSError, ValueError, struct.error, zlib.error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
