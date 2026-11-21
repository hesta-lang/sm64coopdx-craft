import base64
import pathlib
import struct
import subprocess
import sys
import tempfile

script = pathlib.Path("tools/stevecraft_assets/embed_block_textures.py")
with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary) / "assets"
    out = pathlib.Path(temporary) / "embedded.lua"
    for name in (
        "stone", "dirt", "grass_block_top", "grass_block_side",
        "oak_planks", "cobblestone", "glass", "bricks", "sand", "bedrock",
    ):
        path = root / "textures" / "block" / (name + ".png")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0DIHDR" + struct.pack(">II", 16, 16) + b"\x08\x06\x00\x00\x00" + b"x" * 8)
    result = subprocess.run(
        [sys.executable, str(script), "--asset-root", str(root), "--output", str(out)],
        check=True, capture_output=True, text=True,
    )
    text = out.read_text(encoding="utf-8")
    assert text.count("[[") == 10, "embedded manifest did not include all 10 required block textures"
    assert '["textures/block/grass_block_top.png"]' in text
    print("PASS: embedded resource manifest generator and required-texture validation")
