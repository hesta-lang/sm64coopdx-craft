#!/usr/bin/env python3
"""Resolve and download an official Minecraft Java server JAR by exact version."""
from __future__ import annotations
import argparse, hashlib, json, re, sys, urllib.request
from pathlib import Path
from urllib.parse import urlparse
from typing import Any

MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
MAX_BYTES = 512 * 1024 * 1024
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z0-9.-]+)?$")


def official_url(url: str, host: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != host:
        raise ValueError(f"Refusing non-official Minecraft URL: {url}")


def read_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "SteveCraft-Data-Importer/0.3"})
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read(16 * 1024 * 1024 + 1)
    if len(raw) > 16 * 1024 * 1024: raise ValueError("Mojang metadata exceeded 16 MiB")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict): raise ValueError("Mojang metadata was not a JSON object")
    return value


def resolve(version: str) -> tuple[str, str, int | None]:
    if not VERSION_RE.fullmatch(version): raise ValueError(f"Invalid Minecraft version: {version!r}")
    official_url(MANIFEST, "piston-meta.mojang.com")
    manifest = read_json(MANIFEST)
    entry = next((x for x in manifest.get("versions", []) if x.get("id") == version), None)
    if entry is None: raise ValueError(f"Minecraft version {version} not found in Mojang's manifest")
    meta_url = entry.get("url")
    if not isinstance(meta_url, str): raise ValueError("Version metadata URL missing")
    official_url(meta_url, "piston-meta.mojang.com")
    metadata = read_json(meta_url)
    server = metadata.get("downloads", {}).get("server", {})
    url, sha1, size = server.get("url"), server.get("sha1"), server.get("size")
    if not isinstance(url, str): raise ValueError("Server JAR URL missing from version metadata")
    official_url(url, "piston-data.mojang.com")
    if not isinstance(sha1, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha1):
        raise ValueError("Server JAR SHA-1 missing or invalid")
    if size is not None and (not isinstance(size, int) or size < 1 or size > MAX_BYTES):
        raise ValueError("Server JAR size is invalid or exceeds 512 MiB")
    return url, sha1.lower(), size


def download(version: str, output: Path) -> dict[str, Any]:
    url, expected_sha1, expected_size = resolve(version)
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix(output.suffix + ".part")
    digest, count = hashlib.sha1(), 0
    request = urllib.request.Request(url, headers={"User-Agent": "SteveCraft-Data-Importer/0.3"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, temp.open("wb") as target:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk: break
                count += len(chunk)
                if count > MAX_BYTES: raise ValueError("Server JAR exceeded 512 MiB")
                digest.update(chunk); target.write(chunk)
        actual = digest.hexdigest()
        if expected_size is not None and count != expected_size:
            raise ValueError(f"Size mismatch: expected {expected_size}, got {count}")
        if actual != expected_sha1: raise ValueError(f"SHA-1 mismatch: expected {expected_sha1}, got {actual}")
        temp.replace(output)
    except Exception:
        temp.unlink(missing_ok=True)
        raise
    return {"minecraft_version": version, "download_url": url, "sha1": actual, "size": count, "output": str(output)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Download an official Minecraft server JAR and verify Mojang SHA-1")
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    try: result = download(args.version, args.out)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"minecraft-server-download: error: {exc}", file=sys.stderr); return 1
    print(json.dumps(result, indent=2)); return 0

if __name__ == "__main__": raise SystemExit(main())
