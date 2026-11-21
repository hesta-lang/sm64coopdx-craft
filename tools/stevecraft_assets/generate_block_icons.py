#!/usr/bin/env python3
"""Create Minecraft-like isometric block icons from the official 16x16 block textures."""
from __future__ import annotations

import argparse
import pathlib
from PIL import Image, ImageDraw

BLOCKS = {
    "stone": ("textures/block/stone.png", "textures/block/stone.png"),
    "dirt": ("textures/block/dirt.png", "textures/block/dirt.png"),
    "grass_block": ("textures/block/grass_block_top.png", "textures/block/grass_block_side.png"),
    "oak_planks": ("textures/block/oak_planks.png", "textures/block/oak_planks.png"),
    "cobblestone": ("textures/block/cobblestone.png", "textures/block/cobblestone.png"),
    "glass": ("textures/block/glass.png", "textures/block/glass.png"),
    "bricks": ("textures/block/bricks.png", "textures/block/bricks.png"),
    "sand": ("textures/block/sand.png", "textures/block/sand.png"),
    "bedrock": ("textures/block/bedrock.png", "textures/block/bedrock.png"),
}


def face(texture: Image.Image, size: tuple[int, int], polygon: list[tuple[int, int]]) -> Image.Image:
    resized = texture.convert("RGBA").resize(size, Image.Resampling.NEAREST)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).polygon(
        [(x - min(p[0] for p in polygon), y - min(p[1] for p in polygon)) for x, y in polygon],
        fill=255,
    )
    layer = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    left = min(p[0] for p in polygon)
    top = min(p[1] for p in polygon)
    layer.paste(resized, (left, top), mask)
    return layer


def build_icon(root: pathlib.Path, name: str, top_path: str, side_path: str) -> pathlib.Path:
    top = Image.open(root / top_path).convert("RGBA")
    side = Image.open(root / side_path).convert("RGBA")
    canvas = Image.new("RGBA", (32, 32), (0, 0, 0, 0))

    # Build side faces first, then the top face over their shared edge.
    right_polygon = [(30, 9), (16, 17), (16, 31), (30, 23)]
    left_polygon = [(2, 9), (16, 17), (16, 31), (2, 23)]
    top_polygon = [(16, 1), (30, 9), (16, 17), (2, 9)]

    right = face(side, (14, 22), right_polygon)
    left = face(side, (14, 22), left_polygon)
    top_layer = face(top, (28, 16), top_polygon)

    # Darken the right and left side panels to imitate Minecraft's inventory
    # item lighting while preserving the block's original pixel texture.
    right = Image.eval(right, lambda v: int(v * 0.58) if v < 250 else v)
    left = Image.eval(left, lambda v: int(v * 0.78) if v < 250 else v)
    canvas.alpha_composite(right)
    canvas.alpha_composite(left)
    canvas.alpha_composite(top_layer)

    output = root / "textures/stevecraft/icons" / f"{name}.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG", optimize=False)
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", type=pathlib.Path, required=True)
    args = parser.parse_args()
    generated = []
    for name, (top_path, side_path) in BLOCKS.items():
        if not (args.asset_root / top_path).is_file():
            raise SystemExit(f"Missing block top texture: {top_path}")
        if not (args.asset_root / side_path).is_file():
            raise SystemExit(f"Missing block side texture: {side_path}")
        path = build_icon(args.asset_root, name, top_path, side_path)
        with Image.open(path) as icon:
            if icon.size != (32, 32) or icon.mode != "RGBA":
                raise SystemExit(f"Invalid generated icon: {path}")
        generated.append(str(path.relative_to(args.asset_root)))
    print(f"Generated {len(generated)} isometric block icons:")
    for path in generated:
        print("  " + path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
