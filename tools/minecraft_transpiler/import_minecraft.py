#!/usr/bin/env python3
"""Import Minecraft Java sources (or CFR-decompile a local JAR) and run mc2sm64.

No game files are downloaded or redistributed. The user supplies the local input
and, for bytecode JARs, a local CFR decompiler JAR.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Iterable

from mc2sm64 import transpile

PACKAGE_RE = re.compile(rb"^\s*package\s+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\s*;", re.MULTILINE)


def safe_archive_sources(archive_path: Path, destination: Path) -> int:
    """Extract only .java entries, rejecting unsafe paths."""
    count = 0
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            name = info.filename
            normalized_name = name.replace("\\\\", "/")
            posix = PurePosixPath(normalized_name)
            if (posix.is_absolute() or ".." in posix.parts
                    or (posix.parts and posix.parts[0].endswith(":"))
                    or not normalized_name.lower().endswith(".java")):
                continue
            target = destination.joinpath(*posix.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(info))
            count += 1
    return count


def decompile_jar(input_jar: Path, cfr_jar: Path, destination: Path) -> None:
    if not cfr_jar.is_file():
        raise FileNotFoundError(f"CFR JAR not found: {cfr_jar}")
    if shutil.which("java") is None:
        raise RuntimeError("Java runtime not found. Install Java 17+ to run CFR.")
    destination.mkdir(parents=True, exist_ok=True)
    command = [
        "java", "-jar", str(cfr_jar), str(input_jar),
        "--outputdir", str(destination), "--silent", "true",
        "--comments", "false",
    ]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "CFR failed").strip()
        raise RuntimeError(f"CFR decompilation failed (exit {completed.returncode}): {detail[-4000:]}")


def package_of(path: Path, source_root: Path) -> str:
    try:
        match = PACKAGE_RE.search(path.read_bytes()[:65536])
    except OSError:
        return ""
    if match:
        return match.group(1).decode("ascii", errors="replace")
    relative = path.relative_to(source_root)
    if len(relative.parts) > 1:
        return ".".join(relative.parts[:-1])
    return ""


def select_sources(source_root: Path, include_packages: Iterable[str],
                   max_sources: int) -> list[Path]:
    prefixes = tuple(p.strip().strip(".") for p in include_packages if p.strip())
    candidates = sorted(source_root.rglob("*.java"))
    selected = []
    for path in candidates:
        package = package_of(path, source_root)
        if prefixes and not any(package == p or package.startswith(p + ".") for p in prefixes):
            continue
        selected.append(path)
        if len(selected) > max_sources:
            raise ValueError(
                f"Source limit exceeded ({max_sources}). Narrow the import with --include-package."
            )
    return selected


def import_and_transpile(input_path: Path, output_path: Path, target: str,
                         cfr_jar: Path | None = None,
                         include_packages: Iterable[str] = (),
                         max_sources: int = 50000,
                         custom_mapping: Path | None = None) -> dict:
    if not input_path.exists():
        raise FileNotFoundError(f"Input does not exist: {input_path}")
    if max_sources < 1:
        raise ValueError("--max-sources must be positive")

    output_path.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mc2sm64-import-") as temp:
        temp_root = Path(temp)
        source_root = temp_root / "sources"
        decompiled = False

        if input_path.is_dir():
            source_root = input_path
        elif input_path.suffix.lower() == ".java":
            source_root.mkdir(parents=True, exist_ok=True)
            shutil.copy2(input_path, source_root / input_path.name)
        elif input_path.suffix.lower() in {".jar", ".zip"}:
            extracted = safe_archive_sources(input_path, source_root)
            if extracted == 0:
                if input_path.suffix.lower() != ".jar":
                    raise ValueError("Archive contains no .java source files.")
                if cfr_jar is None:
                    raise ValueError(
                        "This JAR contains bytecode, not Java source. Supply --cfr-jar "
                        "with a local CFR decompiler JAR to reconstruct approximate sources."
                    )
                decompile_jar(input_path, cfr_jar, source_root)
                decompiled = True
        else:
            raise ValueError("Input must be a Java source file, directory, .jar, or .zip.")

        selected = select_sources(source_root, include_packages, max_sources)
        if not selected:
            raise ValueError("No Java sources matched the selected package filters.")

        selected_root = temp_root / "selected"
        selected_root.mkdir()
        for index, path in enumerate(selected):
            relative = path.relative_to(source_root) if path.is_relative_to(source_root) else Path(path.name)
            destination = selected_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)

        source_hashes = []
        for path in selected:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            source_hashes.append({
                "path": path.relative_to(source_root).as_posix()
                if path.is_relative_to(source_root) else path.name,
                "sha256": digest,
                "package": package_of(path, source_root),
            })

        report = transpile(selected_root, output_path / "generated", target, custom_mapping)
        import_report = {
            "tool": "mc2sm64-importer",
            "version": "0.2.0-alpha",
            "input": input_path.name,
            "input_kind": "decompiled-bytecode-jar" if decompiled else "java-source",
            "cfr_used": decompiled,
            "source_count": len(selected),
            "package_filters": list(include_packages),
            "source_inventory": source_hashes,
            "transpilation": report,
            "important_note": (
                "CFR reconstructs approximate Java source from bytecode; it cannot recover "
                "comments, original formatting, or all original source-level constructs."
                if decompiled else
                "Java source was imported as supplied; no bytecode decompilation was performed."
            ),
        }
        (output_path / "import_report.json").write_text(
            json.dumps(import_report, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return import_report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Import local Minecraft Java sources, optionally decompile a JAR with CFR, and generate SM64CoopDX Lua/C."
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--target", choices=("lua", "c", "both"), default="lua")
    parser.add_argument("--cfr-jar", type=Path,
                        help="Local CFR decompiler JAR. Required only for bytecode-only Minecraft JARs.")
    parser.add_argument("--include-package", action="append", default=[],
                        help="Import only this Java package prefix; can be repeated.")
    parser.add_argument("--max-sources", type=int, default=50000)
    parser.add_argument("--mapping", type=Path)
    args = parser.parse_args()
    try:
        report = import_and_transpile(
            args.input, args.out, args.target, args.cfr_jar,
            args.include_package, args.max_sources, args.mapping,
        )
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"mc2sm64-import: error: {exc}", file=sys.stderr)
        return 1
    transpilation = report["transpilation"]
    print(json.dumps({
        "status": "imported",
        "input_kind": report["input_kind"],
        "source_count": report["source_count"],
        "classes": transpilation["classes"],
        "methods_seen": transpilation["methods_seen"],
        "generated_methods": transpilation["generated_methods"],
        "report": str(args.out / "import_report.json"),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
