#!/usr/bin/env python3
"""Extract the exact Minecraft Java HUD, block textures and selected sounds."""
from __future__ import annotations
import argparse
import json
import pathlib
import hashlib
import urllib.request

MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
HUD_TEXTURES = [
    "textures/gui/sprites/hud/hotbar.png",
    "textures/gui/sprites/hud/hotbar_selection.png",
    "textures/gui/sprites/hud/hotbar_offhand_left.png",
    "textures/gui/sprites/hud/hotbar_offhand_right.png",
    "textures/gui/sprites/hud/crosshair.png",
    "textures/gui/sprites/hud/armor_full.png",
    "textures/gui/sprites/hud/armor_half.png",
    "textures/gui/sprites/hud/armor_empty.png",
    "textures/gui/sprites/hud/food_full.png",
    "textures/gui/sprites/hud/food_half.png",
    "textures/gui/sprites/hud/food_empty.png",
    "textures/gui/sprites/hud/heart/full.png",
    "textures/gui/sprites/hud/heart/half.png",
    "textures/gui/sprites/hud/heart/container.png",
    "textures/gui/sprites/hud/experience_bar_background.png",
    "textures/gui/sprites/hud/experience_bar_progress.png",
]
BLOCK_TEXTURES = [
    "textures/block/stone.png",
    "textures/block/dirt.png",
    "textures/block/grass_block_top.png",
    "textures/block/grass_block_side.png",
    "textures/block/oak_planks.png",
    "textures/block/cobblestone.png",
    "textures/block/glass.png",
    "textures/block/bricks.png",
    "textures/block/sand.png",
    "textures/block/bedrock.png",
]
SOUND_EVENTS = {
    "stone_step": "block.stone.step",
    "stone_place": "block.stone.place",
    "stone_break": "block.stone.break",
    "dirt_step": "block.gravel.step",
    "dirt_place": "block.gravel.place",
    "dirt_break": "block.gravel.break",
    "grass_step": "block.grass.step",
    "grass_place": "block.grass.place",
    "grass_break": "block.grass.break",
    "wood_step": "block.wood.step",
    "wood_place": "block.wood.place",
    "wood_break": "block.wood.break",
    "glass_step": "block.glass.step",
    "glass_place": "block.glass.place",
    "glass_break": "block.glass.break",
    "sand_step": "block.sand.step",
    "sand_place": "block.sand.place",
    "sand_break": "block.sand.break",
}

def fetch_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "SteveCraft asset extractor"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)

def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "SteveCraft asset extractor"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()

def download_index_asset(index: dict, key: str) -> bytes:
    entry = index.get("objects", {}).get(key)
    if entry is None:
        raise KeyError(f"Asset not found in official version index: {key}")
    digest = entry["hash"]
    data = fetch_bytes(f"https://resources.download.minecraft.net/{digest[:2]}/{digest}")
    actual = hashlib.sha1(data).hexdigest()
    if actual != digest:
        raise ValueError(f"SHA-1 mismatch for {key}: expected {digest}, got {actual}")
    return data

def write_asset(root: pathlib.Path, relative: str, data: bytes):
    destination = root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return destination

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="26.3")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    manifest = fetch_json(MANIFEST_URL)
    release = next((entry for entry in manifest["versions"] if entry["id"] == args.version), None)
    if release is None:
        raise SystemExit(f"Minecraft Java version {args.version!r} is not in the official manifest.")
    metadata = fetch_json(release["url"])
    asset_index = fetch_json(metadata["assetIndex"]["url"])
    assets = args.output

    copied = []
    missing = []
    for relative in HUD_TEXTURES + BLOCK_TEXTURES:
        key = "minecraft/" + relative
        try:
            data = download_index_asset(asset_index, key)
            write_asset(assets, relative, data)
            copied.append(relative)
        except KeyError:
            missing.append(relative)

    try:
        sounds = json.loads(download_index_asset(asset_index, "minecraft/sounds.json"))
    except KeyError:
        sounds = {}

    sound_copied = []
    for output_name, event_name in SOUND_EVENTS.items():
        entry = sounds.get(event_name)
        if not isinstance(entry, dict):
            missing.append("sounds.json:" + event_name)
            continue
        candidates = entry.get("sounds", [])
        source = next((item for item in candidates if isinstance(item, dict) or isinstance(item, str)), None)
        if source is None:
            missing.append("sounds.json:" + event_name)
            continue
        sound_name = source.get("name") if isinstance(source, dict) else source
        sound_name = sound_name.removeprefix("minecraft:")
        sound_key = "minecraft/sounds/" + sound_name + ".ogg"
        try:
            data = download_index_asset(asset_index, sound_key)
            write_asset(assets, "sounds/" + output_name + ".ogg", data)
            sound_copied.append(output_name)
        except KeyError:
            missing.append(sound_key)

    report = {
        "minecraft_version": args.version,
        "hud_and_block_textures": copied,
        "sounds": sound_copied,
        "missing": missing,
    }
    (assets / "stevecraft-assets.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not any(path.startswith("textures/gui/sprites/hud/hotbar") for path in copied):
        raise SystemExit("The official Minecraft hotbar sprite was not extracted.")
    if not any(path.startswith("textures/block/stone") for path in copied):
        raise SystemExit("The official Minecraft stone block texture was not extracted.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
