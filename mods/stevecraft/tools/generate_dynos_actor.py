#!/usr/bin/env python3
"""Convert Mojang's classic humanoid Bedrock geometry + Steve skin to DynOS C sources."""
from __future__ import annotations
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source"
ACTOR = ROOT / "actors" / "steve"
PIXEL_TO_SM64 = 5
GEO_SCALE_16_16 = 61440  # 0.9375

BONE_TO_PART = {
    "body": "body", "jacket": "body",
    "head": "head", "hat": "head",
    "leftArm": "left_arm", "leftSleeve": "left_arm",
    "rightArm": "right_arm", "rightSleeve": "right_arm",
    "leftLeg": "left_leg", "leftPants": "left_leg",
    "rightLeg": "right_leg", "rightPants": "right_leg",
}
BASE_BONES = {"body", "head", "leftArm", "rightArm", "leftLeg", "rightLeg"}
PART_ORDER = ["body", "head", "left_arm", "right_arm", "left_leg", "right_leg"]

def read_source():
    model = json.loads((SOURCE / "humanoid.custom.geo.json").read_text())
    geometry = model["minecraft:geometry"][0]
    skin = Image.open(SOURCE / "steve.png").convert("RGBA")
    if skin.size != (64, 64):
        raise ValueError(f"Expected a 64x64 Steve skin, received {skin.size}")
    return geometry, skin

def face_specs(origin, size, uv, bounds):
    x, y, z = origin
    w, h, d = size
    u, v = uv
    x0, y0, z0, x1, y1, z1 = bounds
    return {
      "front": ((u+d, v+d, w, h), [(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)], (0,0,127)),
      "back": ((u+2*d+w, v+d, w, h), [(x1,y0,z0),(x0,y0,z0),(x0,y1,z0),(x1,y1,z0)], (0,0,-127)),
      "right": ((u, v+d, d, h), [(x1,y0,z1),(x1,y0,z0),(x1,y1,z0),(x1,y1,z1)], (127,0,0)),
      "left": ((u+d+w, v+d, d, h), [(x0,y0,z0),(x0,y0,z1),(x0,y1,z1),(x0,y1,z0)], (-127,0,0)),
      "top": ((u+d, v, w, d), [(x0,y1,z1),(x1,y1,z1),(x1,y1,z0),(x0,y1,z0)], (0,127,0)),
      "bottom": ((u+d+w, v, w, d), [(x0,y0,z0),(x1,y0,z0),(x1,y0,z1),(x0,y0,z1)], (0,-127,0)),
    }

def bone_data(geometry):
    by_name = {bone["name"]: bone for bone in geometry["bones"]}
    result = {part: [] for part in PART_ORDER}
    pivots = {}
    for bone in geometry["bones"]:
        name = bone["name"]
        if name not in BONE_TO_PART:
            continue
        part = BONE_TO_PART[name]
        pivot = tuple(bone.get("pivot", by_name.get(bone.get("parent", "root"), {}).get("pivot", [0,0,0])))
        pivots.setdefault(part, pivot)
        if tuple(pivot) != tuple(pivots[part]):
            raise ValueError(f"Overlay bone {name} has a different pivot from {part}")
        for index, cube in enumerate(bone.get("cubes", [])):
            result[part].append({
                "name": name, "cube_index": index,
                "origin": tuple(cube["origin"]), "size": tuple(cube["size"]),
                "uv": tuple(cube["uv"]), "inflate": float(cube.get("inflate", 0.0)),
                "overlay": name not in BASE_BONES,
            })
    for part in PART_ORDER:
        if not result[part] or part not in pivots:
            raise ValueError(f"Missing required Steve bone geometry: {part}")
    return result, pivots

def emit_texture_inc():
    (ACTOR / "texture.inc.c").write_text(
        'ALIGNED8 const Texture steve_skin_upper[] = {\n'
        '#include "actors/steve/steve_skin_upper.rgba16.inc.c"\n'
        '};\n'
        'ALIGNED8 const Texture steve_skin_lower[] = {\n'
        '#include "actors/steve/steve_skin_lower.rgba16.inc.c"\n'
        '};\n'
    )

def emit_model(parts, pivots):
    out = []
    cube_names = {part: {"base": [], "overlay": []} for part in PART_ORDER}
    for part in PART_ORDER:
        px, py, pz = pivots[part]
        for index, cube in enumerate(parts[part]):
            origin, size, uv = cube["origin"], cube["size"], cube["uv"]
            x, y, z = origin
            w, h, d = size
            inflate = cube["inflate"]
            bounds = (x-inflate, y-inflate, z-inflate,
                      x+w+inflate, y+h+inflate, z+d+inflate)
            box_name = f"steve_{part}_{'outer' if cube['overlay'] else 'base'}_{index}"
            face_data = face_specs(origin, size, uv, bounds)
            emitted = []
            texture_half = None
            for face, (rect, positions, normal) in face_data.items():
                ru, rv, rw, rh = rect
                if rv >= 0 and rv + rh <= 32:
                    tex, y_offset = "steve_skin_upper", 0
                elif rv >= 32 and rv + rh <= 64:
                    tex, y_offset = "steve_skin_lower", 32
                else:
                    raise ValueError(f"UV face crosses atlas split: {box_name}/{face}: {rect}")
                if texture_half is None:
                    texture_half = tex
                if texture_half != tex:
                    raise ValueError(f"Cube spans skin texture halves: {box_name}")
                u0, u1 = ru, ru+rw
                v0, v1 = rv-y_offset, rv+rh-y_offset
                if face in ("front", "back", "right", "left"):
                    uv_corners = [(u0,v1),(u1,v1),(u1,v0),(u0,v0)]
                else:
                    uv_corners = [(u0,v0),(u1,v0),(u1,v1),(u0,v1)]
                vtx = f"{box_name}_{face}_vtx"
                out.append(f"const Vtx {vtx}[4] = {{")
                for (vx,vy,vz), (tu,tv) in zip(positions, uv_corners):
                    sx = round((vx-px)*PIXEL_TO_SM64)
                    sy = round((vy-py)*PIXEL_TO_SM64)
                    sz = round((vz-pz)*PIXEL_TO_SM64)
                    out.append("    {" + "{{" + f"{sx}, {sy}, {sz}" + "}, 0, {" +
                               f"{round(tu*32)}, {round(tv*32)}" + "}, {" +
                               f"{normal[0]}, {normal[1]}, {normal[2]}, 255" + "}}},")
                out.append("};")
                emitted.append(vtx)
            display_list = f"{box_name}_dl"
            out.append(f"const Gfx {display_list}[] = {{")
            out.append("    gsDPPipeSync(),")
            out.append("    gsDPSetCombineMode(G_CC_MODULATEIA, G_CC_MODULATEIA),")
            out.append("    gsSPTexture(0xFFFF, 0xFFFF, 0, 0, 1),")
            out.append(f"    gsDPLoadTextureBlock({texture_half}, G_IM_FMT_RGBA, G_IM_SIZ_16b, 64, 32, 0, G_TX_CLAMP, G_TX_NOMIRROR, G_TX_NOLOD, G_TX_CLAMP, G_TX_NOMIRROR, G_TX_NOLOD),")
            for vtx in emitted:
                out += [f"    gsSPVertex({vtx}, 4, 0),",
                        "    gsSP1Triangle(0, 1, 2, 0),",
                        "    gsSP1Triangle(0, 2, 3, 0),"]
            out += ["    gsSPEndDisplayList(),", "};", ""]
            layer = "overlay" if cube["overlay"] else "base"
            cube_names[part][layer].append(display_list)
    for part in PART_ORDER:
        for layer in ("base", "overlay"):
            if not cube_names[part][layer]:
                continue
            name = f"steve_{part}_{layer}_dl"
            out.append(f"const Gfx {name}[] = {{")
            for display_list in cube_names[part][layer]:
                out.append(f"    gsSPDisplayList({display_list}),")
            out += ["    gsSPEndDisplayList(),", "};", ""]
    (ACTOR / "model.inc.c").write_text("\n".join(out) + "\n")

def emit_geo():
    geo = f'''const GeoLayout steve_geo[] = {{
    GEO_NODE_START(),
    GEO_OPEN_NODE(),
        GEO_SCALE(0x00, {GEO_SCALE_16_16}),
        GEO_OPEN_NODE(),
            GEO_ANIMATED_PART(LAYER_OPAQUE, 0, 0, 0, NULL),
            GEO_OPEN_NODE(),
                GEO_ANIMATED_PART(LAYER_OPAQUE, 0, 60, 0, NULL),
                GEO_OPEN_NODE(),
                    GEO_ANIMATED_PART(LAYER_OPAQUE, 0, 60, 0, steve_body_base_dl),
                    GEO_OPEN_NODE(),
                        GEO_DISPLAY_LIST(LAYER_ALPHA, steve_body_overlay_dl),
                        GEO_ANIMATED_PART(LAYER_OPAQUE, 0, 0, 0, steve_head_base_dl),
                        GEO_OPEN_NODE(),
                            GEO_DISPLAY_LIST(LAYER_ALPHA, steve_head_overlay_dl),
                        GEO_CLOSE_NODE(),
                        GEO_ANIMATED_PART(LAYER_OPAQUE, 25, -10, 0, steve_left_arm_base_dl),
                        GEO_OPEN_NODE(),
                            GEO_DISPLAY_LIST(LAYER_ALPHA, steve_left_arm_overlay_dl),
                        GEO_CLOSE_NODE(),
                        GEO_ANIMATED_PART(LAYER_OPAQUE, -25, -10, 0, steve_right_arm_base_dl),
                        GEO_OPEN_NODE(),
                            GEO_DISPLAY_LIST(LAYER_ALPHA, steve_right_arm_overlay_dl),
                        GEO_CLOSE_NODE(),
                    GEO_CLOSE_NODE(),
                GEO_CLOSE_NODE(),
            GEO_CLOSE_NODE(),
            GEO_ANIMATED_PART(LAYER_OPAQUE, 10, 60, 0, steve_left_leg_base_dl),
            GEO_OPEN_NODE(),
                GEO_DISPLAY_LIST(LAYER_ALPHA, steve_left_leg_overlay_dl),
            GEO_CLOSE_NODE(),
            GEO_ANIMATED_PART(LAYER_OPAQUE, -10, 60, 0, steve_right_leg_base_dl),
            GEO_OPEN_NODE(),
                GEO_DISPLAY_LIST(LAYER_ALPHA, steve_right_leg_overlay_dl),
            GEO_CLOSE_NODE(),
        GEO_CLOSE_NODE(),
    GEO_CLOSE_NODE(),
    GEO_RETURN(),
}};
'''
    (ACTOR / "geo.inc.c").write_text(geo)

def main():
    ACTOR.mkdir(parents=True, exist_ok=True)
    geometry, skin = read_source()
    skin.crop((0,0,64,32)).save(ACTOR/"steve_skin_upper.rgba16.png", optimize=True)
    skin.crop((0,32,64,64)).save(ACTOR/"steve_skin_lower.rgba16.png", optimize=True)
    parts, pivots = bone_data(geometry)
    emit_texture_inc()
    emit_model(parts, pivots)
    emit_geo()
    metadata = {
      "source_geometry": "source/humanoid.custom.geo.json (Mojang bedrock-samples, format_version 1.21.0)",
      "source_skin": "source/steve.png (Mojang bedrock-samples, 64x64)",
      "model": "Classic Steve with 4px arms, hat/jacket/sleeve/pants outer layers",
      "mesh": "6 articulated body parts; base and alpha outer layers use separate render layers",
      "units": "5 SM64 units per Bedrock model pixel; GEO_SCALE 0.9375",
      "textures": "Two 64x32 PNG atlas halves, loaded as RGBA16 tiles (4096 bytes each).",
      "animations": "No custom animation clips generated yet; GeoLayout preserves head, arms, and legs as independent animated parts."
    }
    (ACTOR/"MODEL_SOURCE.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("generated actor source:", ACTOR)
    for path in sorted(ACTOR.iterdir()):
        print(path.name, path.stat().st_size)

if __name__ == "__main__":
    main()
