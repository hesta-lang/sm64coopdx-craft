#!/usr/bin/env python3
"""Extract normalized block resource metadata from an official Minecraft Java client JAR.

No textures, audio, raw resource files, or Minecraft source code are copied.
Properties available only from Java registries/runtime remain null.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
FORMAT_VERSION = "1.0.0"
RUNTIME_FIELDS = [
    "destroy_speed", "explosion_resistance", "friction", "collision_shapes",
    "occlusion_shapes", "fluid_state", "light_emission", "redstone_properties"
]


def read_json(data: bytes, source_name: str) -> Any:
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Invalid UTF-8 JSON resource: {source_name}: {exc}") from exc


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_client_jar(version: str, destination: Path) -> str:
    headers = {"User-Agent": "SteveCraft-BlockMetadata-Extractor/1.0"}
    request = urllib.request.Request(MANIFEST_URL, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        manifest = json.load(response)
    entry = next((item for item in manifest.get("versions", []) if item.get("id") == version), None)
    if entry is None:
        raise ValueError(f"Minecraft version {version!r} is not in Mojang's version manifest")

    request = urllib.request.Request(entry["url"], headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        version_data = json.load(response)
    client = version_data.get("downloads", {}).get("client")
    if not client or not client.get("url") or not client.get("sha1"):
        raise ValueError(f"No official client JAR metadata was found for {version}")

    request = urllib.request.Request(client["url"], headers=headers)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)

    actual = sha1_file(destination)
    if actual.lower() != client["sha1"].lower():
        destination.unlink(missing_ok=True)
        raise ValueError(f"Client JAR SHA-1 mismatch: expected {client['sha1']}, got {actual}")
    return actual


def download_sound_definitions(version: str) -> dict[str, Any]:
    """Download sounds.json from the official version asset index (not the client JAR)."""
    headers = {"User-Agent": "SteveCraft-BlockMetadata-Extractor/1.0"}
    with urllib.request.urlopen(
        urllib.request.Request(MANIFEST_URL, headers=headers), timeout=60
    ) as response:
        manifest = json.load(response)
    entry = next((item for item in manifest.get("versions", []) if item.get("id") == version), None)
    if entry is None:
        raise ValueError(f"Minecraft version {version!r} is not in Mojang's version manifest")
    with urllib.request.urlopen(
        urllib.request.Request(entry["url"], headers=headers), timeout=60
    ) as response:
        metadata = json.load(response)
    asset_index_info = metadata.get("assetIndex")
    if not isinstance(asset_index_info, dict) or not asset_index_info.get("url"):
        raise ValueError(f"No asset index metadata was found for Minecraft {version}")
    with urllib.request.urlopen(
        urllib.request.Request(asset_index_info["url"], headers=headers), timeout=60
    ) as response:
        asset_index = json.load(response)

    definitions: dict[str, Any] = {}
    for asset_path, item in asset_index.get("objects", {}).items():
        path = PurePosixPath(asset_path)
        if path.name != "sounds.json" or len(path.parts) != 2:
            continue
        namespace = path.parts[0]
        digest = item.get("hash") if isinstance(item, dict) else None
        if not isinstance(digest, str) or len(digest) != 40:
            continue
        url = f"https://resources.download.minecraft.net/{digest[:2]}/{digest}"
        with urllib.request.urlopen(
            urllib.request.Request(url, headers=headers), timeout=60
        ) as response:
            source = read_json(response.read(), asset_path)
        if isinstance(source, dict):
            definitions[namespace] = source

    if not definitions:
        raise ValueError(f"No sounds.json resource was found in the {version} asset index")
    return definitions


def normalize_id(value: str, namespace: str = "minecraft") -> str:
    value = str(value)
    return value if ":" in value else f"{namespace}:{value}"


def resource_files(archive: zipfile.ZipFile, folder: str, root: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for name in archive.namelist():
        if not name.endswith(".json"):
            continue
        parts = PurePosixPath(name).parts
        if len(parts) < 4 or parts[0] != root:
            continue
        try:
            index = parts.index(folder)
        except ValueError:
            continue
        if index < 2 or index >= len(parts) - 1:
            continue
        found[f"{parts[1]}:{'/'.join(parts[index + 1:])[:-5]}"] = name
    return found


def parse_selector(selector: str) -> dict[str, str]:
    properties = {}
    for part in selector.split(","):
        if "=" in part:
            key, value = part.split("=", 1)
            properties[key.strip()] = value.strip()
    return properties


def model_applications(value: Any, namespace: str) -> list[dict[str, Any]]:
    entries = value if isinstance(value, list) else [value]
    result = []
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("model"), str):
            result.append({
                "model_id": normalize_id(entry["model"], namespace),
                "x": entry.get("x", 0),
                "y": entry.get("y", 0),
                "z": entry.get("z", 0),
                "uvlock": bool(entry.get("uvlock", False)),
                "weight": entry.get("weight", 1)
            })
    return result


def referenced_model_ids(source: dict[str, Any], namespace: str) -> list[str]:
    result = set()
    variants = source.get("variants", {})
    if isinstance(variants, dict):
        for value in variants.values():
            result.update(item["model_id"] for item in model_applications(value, namespace))
    multipart = source.get("multipart", [])
    if isinstance(multipart, list):
        for part in multipart:
            if isinstance(part, dict):
                result.update(item["model_id"] for item in model_applications(part.get("apply"), namespace))
    return sorted(result)


def summarize_blockstate(source: dict[str, Any], namespace: str) -> dict[str, Any]:
    variants = []
    raw_variants = source.get("variants", {})
    if isinstance(raw_variants, dict):
        for selector, value in sorted(raw_variants.items()):
            variants.append({
                "selector": str(selector),
                "properties": parse_selector(str(selector)),
                "models": model_applications(value, namespace)
            })
    multipart = []
    raw_multipart = source.get("multipart", [])
    if isinstance(raw_multipart, list):
        for part in raw_multipart:
            if isinstance(part, dict):
                multipart.append({
                    "when": part.get("when"),
                    "models": model_applications(part.get("apply"), namespace)
                })
    return {"variants": variants, "multipart": multipart}


def summarize_model(model_id: str, archive: zipfile.ZipFile, index: dict[str, str]) -> dict[str, Any]:
    path = index.get(model_id)
    result = {
        "id": model_id, "parent": None, "texture_slots": {},
        "elements": [], "resource_found": path is not None
    }
    if path is None:
        return result
    namespace = model_id.split(":", 1)[0]
    source = read_json(archive.read(path), path)
    if not isinstance(source, dict):
        raise ValueError(f"Block model is not an object: {path}")
    parent = source.get("parent")
    if isinstance(parent, str):
        result["parent"] = normalize_id(parent, namespace)
    textures = source.get("textures", {})
    if isinstance(textures, dict):
        for slot, value in sorted(textures.items()):
            result["texture_slots"][str(slot)] = (
                normalize_id(value, namespace)
                if isinstance(value, str) and not value.startswith("#") else value
            )
    elements = source.get("elements", [])
    if isinstance(elements, list):
        for element in elements:
            if not isinstance(element, dict):
                continue
            item = {}
            for key in ("from", "to"):
                if isinstance(element.get(key), list):
                    item[key] = element[key]
            rotation = element.get("rotation")
            if isinstance(rotation, dict):
                item["rotation"] = {
                    key: rotation[key] for key in ("origin", "axis", "angle", "rescale")
                    if key in rotation
                }
            faces = element.get("faces", {})
            if isinstance(faces, dict):
                item["faces"] = {
                    direction: {
                        key: face[key] for key in ("texture", "cullface", "tintindex")
                        if key in face
                    }
                    for direction, face in sorted(faces.items()) if isinstance(face, dict)
                }
            result["elements"].append(item)
    return result


def collect_ingredient_ids(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, nested in value.items():
            if key == "item" and isinstance(nested, str):
                found.add(normalize_id(nested))
            elif key == "items" and isinstance(nested, list):
                found.update(normalize_id(item) for item in nested if isinstance(item, str))
            found.update(collect_ingredient_ids(nested))
    elif isinstance(value, list):
        for nested in value:
            found.update(collect_ingredient_ids(nested))
    return found


def summarize_recipe(recipe_id: str, source: dict[str, Any]) -> dict[str, Any]:
    result_source = source.get("result")
    result_id, result_count = None, 1
    if isinstance(result_source, str):
        result_id = normalize_id(result_source)
    elif isinstance(result_source, dict):
        raw_id = result_source.get("id", result_source.get("item"))
        if isinstance(raw_id, str):
            result_id = normalize_id(raw_id)
        result_count = result_source.get("count", 1)
    return {
        "id": recipe_id, "type": source.get("type"),
        "ingredient_ids": sorted(collect_ingredient_ids(source)),
        "result_id": result_id, "result_count": result_count
    }


def extract_from_jar(jar_path: Path, version: str, output_path: Path, jar_sha1: str | None = None, external_sound_definitions: dict[str, Any] | None = None) -> dict[str, Any]:
    with zipfile.ZipFile(jar_path) as archive:
        blockstate_index = resource_files(archive, "blockstates", "assets")
        model_index = resource_files(archive, "models", "assets")
        recipe_index = {}
        loot_index = {}
        for name in archive.namelist():
            parts = PurePosixPath(name).parts
            if len(parts) < 4 or parts[0] != "data" or not name.endswith(".json"):
                continue
            if parts[2] in ("recipe", "recipes"):
                recipe_index[f"{parts[1]}:{'/'.join(parts[3:])[:-5]}"] = name
            if len(parts) >= 5 and parts[2] in ("loot_table", "loot_tables") and parts[3] == "blocks":
                loot_index[f"{parts[1]}:{'/'.join(parts[4:])[:-5]}"] = name

        blocks = []
        models = {}
        for block_id, path in sorted(blockstate_index.items()):
            raw = read_json(archive.read(path), path)
            if not isinstance(raw, dict):
                continue
            namespace = block_id.split(":", 1)[0]
            referenced = referenced_model_ids(raw, namespace)
            for model_id in referenced:
                if model_id not in models:
                    models[model_id] = summarize_model(model_id, archive, model_index)
            blocks.append({
                "id": block_id,
                "blockstate": summarize_blockstate(raw, namespace),
                "model_ids": referenced,
                "resource_flags": {"loot_table_id": block_id if block_id in loot_index else None},
                "runtime_properties": {
                    "destroy_speed": None, "explosion_resistance": None, "friction": None,
                    "collision_shapes": None, "occlusion_shapes": None, "fluid_state": None,
                    "light_emission": None, "redstone_properties": None,
                    "status": "requires_java_runtime"
                }
            })

        tags = {}
        for name in archive.namelist():
            parts = PurePosixPath(name).parts
            if len(parts) < 5 or parts[0] != "data" or parts[2:4] != ("tags", "block") or not name.endswith(".json"):
                continue
            tag_id = f"{parts[1]}:{'/'.join(parts[4:])[:-5]}"
            source = read_json(archive.read(name), name)
            values = source.get("values", []) if isinstance(source, dict) else []
            tags[tag_id] = sorted(
                normalize_id(value) if not value.startswith("#") else value
                for value in values if isinstance(value, str)
            )

        recipes = []
        for recipe_id, path in sorted(recipe_index.items()):
            raw = read_json(archive.read(path), path)
            if isinstance(raw, dict):
                recipes.append(summarize_recipe(recipe_id, raw))

        sound_events = []
        for name in archive.namelist():
            parts = PurePosixPath(name).parts
            if len(parts) != 3 or parts[0] != "assets" or parts[2] != "sounds.json":
                continue
            source = read_json(archive.read(name), name)
            if isinstance(source, dict):
                for event, value in sorted(source.items()):
                    sound_events.append({
                        "id": f"{parts[1]}:{event}",
                        "sound_count": len(value.get("sounds", []))
                        if isinstance(value, dict) and isinstance(value.get("sounds", []), list) else 0
                    })

        # sounds.json is a separately downloaded launcher asset in current Java releases.
        for namespace, source in (external_sound_definitions or {}).items():
            if not isinstance(source, dict):
                continue
            for event, value in sorted(source.items()):
                sound_events.append({
                    "id": f"{namespace}:{event}",
                    "sound_count": len(value.get("sounds", []))
                    if isinstance(value, dict) and isinstance(value.get("sounds", []), list) else 0
                })
        sound_events = list({entry["id"]: entry for entry in sound_events}.values())

    result = {
        "format_version": FORMAT_VERSION,
        "minecraft_version": version,
        "source": {"kind": "official_client_jar", "sha1": jar_sha1 or sha1_file(jar_path)},
        "coverage": {
            "blockstate_resource_count": len(blocks),
            "block_model_resource_count": len(models),
            "block_tag_count": len(tags),
            "recipe_resource_count": len(recipes),
            "sound_event_count": len(sound_events),
            "registry_complete": False,
            "runtime_required_fields": RUNTIME_FIELDS,
            "note": (
                "This index covers blockstate resources in the client JAR, not the complete "
                "block registry. Java registry-only properties remain null until a validated "
                "runtime adapter exists."
            )
        },
        "blocks": blocks,
        "models": [models[key] for key in sorted(models)],
        "block_tags": tags,
        "recipes": recipes,
        "sound_events": sorted(sound_events, key=lambda item: item["id"])
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="26.3")
    parser.add_argument("--jar", type=Path, help="Use a local client JAR instead of downloading it")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    jar = args.jar
    downloaded_sha1 = None
    try:
        if jar is None:
            jar = args.output.parent / f"minecraft-{args.version}-client.jar"
            downloaded_sha1 = download_client_jar(args.version, jar)
        if not jar.is_file():
            raise FileNotFoundError(f"Client JAR not found: {jar}")
        sound_definitions = download_sound_definitions(args.version)
        result = extract_from_jar(jar, args.version, args.output, downloaded_sha1, sound_definitions)
        coverage = result["coverage"]
        print(
            f"Indexed {coverage['blockstate_resource_count']} blockstates, "
            f"{coverage['block_model_resource_count']} models, "
            f"{coverage['block_tag_count']} tags, {coverage['recipe_resource_count']} recipes, "
            f"{coverage['sound_event_count']} sound events."
        )
        print(f"Output: {args.output}")
        if downloaded_sha1:
            jar.unlink(missing_ok=True)
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
