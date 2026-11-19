#!/usr/bin/env python3
"""Import Minecraft Java sources and optionally attach Mojang's block-state catalog."""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, subprocess, sys, tempfile, zipfile
from pathlib import Path, PurePosixPath
from typing import Iterable
from mc2sm64 import transpile
from extract_block_states import extract_block_states

PACKAGE_RE = re.compile(rb"^\s*package\s+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\s*;", re.MULTILINE)


def safe_archive_sources(archive_path: Path, destination: Path) -> int:
    """Extract only .java entries, rejecting unsafe archive paths."""
    count = 0
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            name = info.filename
            normalized = name.replace("\\", "/")
            posix = PurePosixPath(normalized)
            if (posix.is_absolute() or ".." in posix.parts
                    or (posix.parts and posix.parts[0].endswith(":"))
                    or not normalized.lower().endswith(".java")):
                continue
            target = destination.joinpath(*posix.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(info))
            count += 1
    return count


def decompile_jar(input_jar: Path, cfr_jar: Path, destination: Path) -> None:
    if not cfr_jar.is_file(): raise FileNotFoundError(f"CFR JAR not found: {cfr_jar}")
    if shutil.which("java") is None: raise RuntimeError("Java runtime not found. Install Java 17+ to run CFR.")
    destination.mkdir(parents=True, exist_ok=True)
    command = ["java", "-jar", str(cfr_jar), str(input_jar), "--outputdir", str(destination), "--silent", "true", "--comments", "false"]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout or "CFR failed").strip()
        raise RuntimeError(f"CFR decompilation failed (exit {completed.returncode}): {detail[-4000:]}")


def package_of(path: Path, root: Path) -> str:
    try: match = PACKAGE_RE.search(path.read_bytes()[:65536])
    except OSError: return ""
    if match: return match.group(1).decode("ascii", errors="replace")
    relative = path.relative_to(root)
    return ".".join(relative.parts[:-1]) if len(relative.parts) > 1 else ""


def select_sources(root: Path, include_packages: Iterable[str], max_sources: int) -> list[Path]:
    prefixes = tuple(p.strip().strip(".") for p in include_packages if p.strip())
    selected = []
    for path in sorted(root.rglob("*.java")):
        package = package_of(path, root)
        if prefixes and not any(package == p or package.startswith(p + ".") for p in prefixes): continue
        selected.append(path)
        if len(selected) > max_sources:
            raise ValueError(f"Source limit exceeded ({max_sources}). Narrow the import with --include-package.")
    return selected


def import_and_transpile(input_path: Path, output_path: Path, target: str,
                         cfr_jar: Path | None = None,
                         include_packages: Iterable[str] = (),
                         max_sources: int = 50000,
                         custom_mapping: Path | None = None,
                         block_report: Path | None = None,
                         minecraft_version: str = "26.3") -> dict:
    if not input_path.exists(): raise FileNotFoundError(f"Input does not exist: {input_path}")
    if max_sources < 1: raise ValueError("--max-sources must be positive")
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
                if input_path.suffix.lower() != ".jar": raise ValueError("Archive contains no .java source files.")
                if cfr_jar is None:
                    raise ValueError("This JAR contains bytecode, not Java source. Supply --cfr-jar with a local CFR decompiler JAR.")
                decompile_jar(input_path, cfr_jar, source_root)
                decompiled = True
        else:
            raise ValueError("Input must be a Java source file, directory, .jar, or .zip.")
        selected = select_sources(source_root, include_packages, max_sources)
        if not selected: raise ValueError("No Java sources matched the selected package filters.")
        selected_root = temp_root / "selected"
        selected_root.mkdir()
        for path in selected:
            relative = path.relative_to(source_root) if path.is_relative_to(source_root) else Path(path.name)
            destination = selected_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        source_hashes = []
        for path in selected:
            source_hashes.append({
                "path": path.relative_to(source_root).as_posix() if path.is_relative_to(source_root) else path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "package": package_of(path, source_root),
            })
        transpilation = transpile(selected_root, output_path / "generated", target, custom_mapping)
        block_catalog = None
        if block_report is not None:
            block_catalog = extract_block_states(block_report, output_path / "block_states", minecraft_version)
        report = {
            "tool": "mc2sm64-importer", "version": "0.3.0-alpha",
            "minecraft_version": minecraft_version,
            "input": input_path.name,
            "input_kind": "decompiled-bytecode-jar" if decompiled else "java-source",
            "cfr_used": decompiled, "source_count": len(selected),
            "package_filters": list(include_packages), "source_inventory": source_hashes,
            "transpilation": transpilation, "block_state_catalog": block_catalog,
            "important_note": (
                "CFR reconstructs approximate Java source from bytecode; it cannot recover comments, original formatting, or all original source-level constructs."
                if decompiled else "Java source was imported as supplied; no bytecode decompilation was performed."
            ),
        }
        (output_path / "import_report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Import Minecraft Java sources, optionally decompile a JAR with CFR, and generate SM64CoopDX Lua/C.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--target", choices=("lua", "c", "both"), default="lua")
    parser.add_argument("--cfr-jar", type=Path, help="Local CFR decompiler JAR, required for bytecode-only JARs.")
    parser.add_argument("--include-package", action="append", default=[], help="Java package prefix; may be repeated.")
    parser.add_argument("--max-sources", type=int, default=50000)
    parser.add_argument("--mapping", type=Path)
    parser.add_argument("--block-report", type=Path, help="Optional Mojang reports/blocks.json or its parent directory.")
    parser.add_argument("--minecraft-version", default="26.3", help="Version label stored in generated catalogs.")
    args = parser.parse_args()
    try:
        report = import_and_transpile(args.input, args.out, args.target, args.cfr_jar,
            args.include_package, args.max_sources, args.mapping, args.block_report, args.minecraft_version)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"mc2sm64-import: error: {exc}", file=sys.stderr); return 1
    transpilation = report["transpilation"]
    print(json.dumps({
        "status": "imported", "minecraft_version": report["minecraft_version"],
        "input_kind": report["input_kind"], "source_count": report["source_count"],
        "classes": transpilation["classes"], "methods_seen": transpilation["methods_seen"],
        "generated_methods": transpilation["generated_methods"],
        "block_state_catalog": report["block_state_catalog"],
        "report": str(args.out / "import_report.json"),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
