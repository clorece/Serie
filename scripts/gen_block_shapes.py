#!/usr/bin/env python3
"""
Generate Serie's voxel block-shape table straight from Minecraft's own block models.

Serie used to carry a hand-written enum of 66 shapes (lib/pt/voxelData.glsl
intersectVoxelShape) dispatched by an if-chain. That could not keep up with the
real game: every fence mapped to one full cross regardless of connection state,
fence arms were modelled as a single slat instead of two planks with a gap, and
most non-full blocks had no shape at all.

Minecraft already ships the exact box lists we want, in assets/minecraft:
  blockstates/<block>.json  - maps a blockstate to model(s) + rotation
  models/block/<model>.json - "elements" with from/to boxes in 1/16 block units

So we read those, resolve model inheritance, apply rotations, and emit:
  1. a block.properties section mapping each blockstate to a shape id
  2. lib/pt/shapeTable.glsl - the packed AABB table the BLAS traverses

Usage:
    python3 scripts/gen_block_shapes.py [--jar PATH] [--check]

--check re-generates into memory and diffs against the committed files, exiting
nonzero on drift; use it to confirm the tree matches the game version.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import re
import sys
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent
SHADERS = REPO / "shaders"
BLOCK_PROPERTIES = SHADERS / "block.properties"
SHAPE_TABLE = SHADERS / "lib" / "pt" / "shapeTable.glsl"

DEFAULT_JAR_GLOBS = [
    Path.home() / ".local/share/ModrinthApp/meta/versions",
    Path.home() / ".minecraft/versions",
]

# Markers delimiting the generated region of block.properties. Everything
# outside them is hand-maintained and preserved verbatim.
GEN_BEGIN = "# >>> GENERATED SHAPES (gen_block_shapes.py) - DO NOT EDIT BY HAND >>>"
GEN_END = "# <<< GENERATED SHAPES <<<"

# --------------------------------------------------------------------------
# id encoding
# --------------------------------------------------------------------------
# Old scheme packed material and shape as 30000 + matClass*100 + shapeId, which
# capped shapes at 99. Model-derived shapes run into the thousands, so widen to:
#
#     mc_Entity.x = SHAPE_ID_BASE + shapeId * 16 + matClass
#
# shapeId  0..4095  (0 = full cube, never emitted as a shaped id)
# matClass 0..15    (0 = no integrated-PBR class; 1..15 as in terrain.glsl)
SHAPE_ID_BASE = 40000
MAT_BITS = 4
MAX_MAT = (1 << MAT_BITS) - 1

# Blocks Serie deliberately keeps out of the voxel grid. Foliage stays excluded
# (confirmed: not worth the fill cost), as do fluids and full-transparent blocks
# that must not occlude GI.
EXCLUDE_SUBSTRINGS = (
    "water", "lava", "bubble_column",
    "grass_block", "short_grass", "tall_grass", "fern", "large_fern",
    "leaves", "vine", "sapling", "seagrass", "kelp", "azalea",
    "flower", "tulip", "orchid", "allium", "bluet", "daisy", "poppy",
    "dandelion", "cornflower", "lily", "rose", "sunflower", "lilac", "peony",
    "wheat", "carrots", "potatoes", "beetroots", "nether_wart", "torchflower",
    "pitcher_crop", "sugar_cane", "bamboo_sapling", "cactus_flower",
    "air", "barrier", "structure_void", "light", "moving_piston",
    "fire", "soul_fire", "nether_portal", "end_portal", "end_gateway",
)

# Blocks whose shape we skip because Serie already handles them through a
# dedicated category (emissive lights keep their own sub-box logic).
SKIP_SHAPE_SUBSTRINGS = (
    "torch", "lantern", "candle", "campfire", "glowstone", "sea_pickle",
    "end_rod", "shroomlight", "froglight", "redstone_lamp",
)

# --------------------------------------------------------------------------
# material classification (carried over from the old gen_shaped_pbr.py table,
# which mapped block-name substrings to terrain.glsl's pbrClass 1..16)
# --------------------------------------------------------------------------

MAT_TABLE = [
    ("cut_copper", 1), ("copper", 1), ("iron", 1), ("gold", 1), ("netherite", 1),
    ("anvil", 1), ("hopper", 1), ("cauldron", 1), ("grindstone", 1), ("chain", 1),
    ("lightning_rod", 1), ("bell", 1), ("brewing", 1),
    ("raw_iron", 2), ("raw_gold", 2), ("raw_copper", 2),
    ("polished_blackstone", 6), ("blackstone", 6), ("polished_deepslate", 6),
    ("deepslate_brick", 6), ("deepslate_tile", 6), ("deepslate", 6), ("obsidian", 6),
    ("nether_brick", 6), ("red_nether_brick", 6),
    ("quartz", 4), ("diamond", 5), ("emerald", 5), ("amethyst", 5), ("prismarine", 7),
    ("glazed_terracotta", 8),
    ("polished_granite", 3), ("polished_diorite", 3), ("polished_andesite", 3),
    ("polished_tuff", 3), ("tuff_brick", 3), ("smooth_stone", 3), ("smooth_sandstone", 3),
    ("smooth_red_sandstone", 3), ("polished_basalt", 3), ("smooth_basalt", 3),
    ("calcite", 3), ("dripstone", 3), ("purpur", 3),
    ("stone_brick", 11), ("mossy_stone_brick", 11), ("mud_brick", 11), ("brick", 11),
    ("end_stone_brick", 11), ("resin_brick", 11),
    ("concrete", 9), ("glazed", 8), ("terracotta", 10), ("wool", 16), ("carpet", 16),
    ("cobbled_deepslate", 12), ("cobblestone", 12), ("mossy_cobblestone", 12),
    ("andesite", 12), ("granite", 12), ("diorite", 12), ("basalt", 12), ("tuff", 12),
    ("cut_sandstone", 12), ("cut_red_sandstone", 12), ("sandstone", 12),
    ("red_sandstone", 12), ("end_stone", 12), ("stonecutter", 12),
    ("snow", 15), ("ladder", 13), ("scaffolding", 13), ("composter", 13),
    ("grass_path", 14), ("_bed", 16),
    ("flower_pot", 10), ("decorated_pot", 10), ("potted", 10),
    ("stone", 12),
    ("stripped", 13), ("planks", 13), ("_log", 13), ("_wood", 13), ("_stem", 13),
    ("_hyphae", 13), ("bamboo", 13), ("chest", 13), ("lectern", 13), ("barrel", 13),
    ("petrified_oak", 13), ("wooden", 13),
    ("oak", 13), ("spruce", 13), ("birch", 13), ("jungle", 13), ("acacia", 13),
    ("mangrove", 13), ("cherry", 13), ("crimson", 13), ("warped", 13), ("pale_oak", 13),
    ("dirt_path", 14), ("farmland", 14), ("coarse_dirt", 14), ("podzol", 14),
    ("mycelium", 14), ("rooted_dirt", 14), ("mud", 14), ("dirt", 14),
    ("red_sand", 15), ("gravel", 15), ("sand", 15),
]


def classify_material(block: str) -> int:
    """Map a block name to terrain.glsl's pbrClass, clamped to the 4-bit field."""
    for sub, cls in MAT_TABLE:
        if sub in block:
            return min(cls, MAX_MAT)
    return 0


# --------------------------------------------------------------------------
# jar loading
# --------------------------------------------------------------------------


def find_jar() -> Path:
    candidates: list[Path] = []
    for root in DEFAULT_JAR_GLOBS:
        if root.is_dir():
            candidates.extend(root.rglob("*.jar"))
    # Prefer the jar that actually carries blockstates, newest first.
    for jar in sorted(candidates, key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            with zipfile.ZipFile(jar) as z:
                if any(n.startswith("assets/minecraft/blockstates/") for n in z.namelist()):
                    return jar
        except zipfile.BadZipFile:
            continue
    raise SystemExit("could not locate a Minecraft client jar containing blockstates; pass --jar")


class Assets:
    """Lazy reader over the client jar's blockstate and model JSON."""

    def __init__(self, jar: Path):
        self.zip = zipfile.ZipFile(jar)
        self._models: dict[str, dict] = {}
        self.blockstates: dict[str, dict] = {}
        for name in self.zip.namelist():
            m = re.fullmatch(r"assets/minecraft/blockstates/([\w/]+)\.json", name)
            if m:
                self.blockstates[m.group(1)] = json.loads(self.zip.read(name))

    def model(self, ref: str) -> dict:
        """Load a model by reference ('minecraft:block/foo' or 'block/foo')."""
        ref = ref.split(":")[-1]
        if ref in self._models:
            return self._models[ref]
        try:
            data = json.loads(self.zip.read(f"assets/minecraft/models/{ref}.json"))
        except KeyError:
            data = {}
        self._models[ref] = data
        return data

    def elements(self, ref: str, _depth: int = 0) -> list[dict]:
        """Resolve a model's elements, walking the parent chain when absent."""
        if _depth > 12:
            return []
        data = self.model(ref)
        if "elements" in data:
            return data["elements"]
        parent = data.get("parent")
        if parent:
            return self.elements(parent, _depth + 1)
        return []


# --------------------------------------------------------------------------
# geometry
# --------------------------------------------------------------------------

Box = tuple[float, float, float, float, float, float]  # xmin ymin zmin xmax ymax zmax


def rotate_box(box: Box, x_deg: int, y_deg: int) -> Box:
    """Rotate an AABB about the block centre and re-bound it.

    Blockstate rotations are always multiples of 90 degrees, so this stays exact:
    a rotated axis-aligned box is still axis-aligned.
    """
    xs = (box[0], box[3])
    ys = (box[1], box[4])
    zs = (box[2], box[5])
    pts = [(x, y, z) for x in xs for y in ys for z in zs]

    # Handedness calibrated against two unambiguous vanilla models:
    #   ladder  facing=north is unrotated with its plane at z=15.2, and a ladder
    #           faces away from its wall, so y=90 (facing=east) must carry +Z to -X.
    #   button  face=floor is unrotated with its pad at y=0..2, and face=wall
    #           facing=north uses x=90, so x=90 must carry -Y to +Z.
    # Both give the forms below; getting these transposed silently mirrors every
    # rotated block (a fence's east arm lands on its west side).
    def rot_x(p, deg):
        x, y, z = p
        c, s = int(round(math.cos(math.radians(deg)))), int(round(math.sin(math.radians(deg))))
        dy, dz = y - 8, z - 8
        return (x, dy * c + dz * s + 8, -dy * s + dz * c + 8)

    def rot_y(p, deg):
        x, y, z = p
        c, s = int(round(math.cos(math.radians(deg)))), int(round(math.sin(math.radians(deg))))
        dx, dz = x - 8, z - 8
        return (dx * c - dz * s + 8, y, dx * s + dz * c + 8)

    if x_deg:
        pts = [rot_x(p, x_deg) for p in pts]
    if y_deg:
        pts = [rot_y(p, y_deg) for p in pts]

    return (
        min(p[0] for p in pts), min(p[1] for p in pts), min(p[2] for p in pts),
        max(p[0] for p in pts), max(p[1] for p in pts), max(p[2] for p in pts),
    )


def element_box(el: dict) -> Box | None:
    """Extract an element's AABB, conservatively bounding any element rotation."""
    try:
        fx, fy, fz = (float(v) for v in el["from"])
        tx, ty, tz = (float(v) for v in el["to"])
    except (KeyError, TypeError, ValueError):
        return None
    box = (min(fx, tx), min(fy, ty), min(fz, tz), max(fx, tx), max(fy, ty), max(fz, tz))

    rot = el.get("rotation")
    if rot:
        # Non-90-degree element rotations (22.5/45, used by rails, levers, ...)
        # cannot stay axis-aligned; bound the rotated corners instead. Slightly
        # conservative, which is the safe direction for an occluder.
        angle = float(rot.get("angle", 0))
        axis = rot.get("axis", "y")
        ox, oy, oz = (float(v) for v in rot.get("origin", [8, 8, 8]))
        c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
        pts = []
        for px in (box[0], box[3]):
            for py in (box[1], box[4]):
                for pz in (box[2], box[5]):
                    dx, dy, dz = px - ox, py - oy, pz - oz
                    if axis == "x":  # same handedness as rotate_box below
                        dy, dz = dy * c + dz * s, -dy * s + dz * c
                    elif axis == "y":
                        dx, dz = dx * c - dz * s, dx * s + dz * c
                    else:
                        dx, dy = dx * c - dy * s, dx * s + dy * c
                    pts.append((dx + ox, dy + oy, dz + oz))
        box = (
            min(p[0] for p in pts), min(p[1] for p in pts), min(p[2] for p in pts),
            max(p[0] for p in pts), max(p[1] for p in pts), max(p[2] for p in pts),
        )
    return box


def quantise(box: Box) -> Box:
    """Snap to the 1/64-block grid the packed table stores, clamped to the cube.

    Boxes are widened outward so quantisation never opens a hole in an occluder.
    """
    lo = [max(0, min(64, math.floor(v * 4))) for v in box[:3]]
    hi = [max(0, min(64, math.ceil(v * 4))) for v in box[3:]]
    # Planar elements (ladders, banners, a lever's base) can land on an exact
    # grid line, leaving hi == lo. Those would be dropped as degenerate and the
    # occluder would vanish, so give every axis at least one unit of thickness.
    for i in range(3):
        if hi[i] <= lo[i]:
            if hi[i] < 64:
                hi[i] = lo[i] + 1
            else:
                lo[i] = hi[i] - 1
    return (*lo, *hi)


def is_full_cube(boxes: list[Box]) -> bool:
    return any(b[0] <= 0 and b[1] <= 0 and b[2] <= 0 and b[3] >= 64 and b[4] >= 64 and b[5] >= 64
               for b in boxes)


def merge_boxes(boxes: list[Box], limit: int = 12) -> list[Box]:
    """Drop duplicates/contained boxes; if still over budget, merge the closest pairs.

    A shape's box list is scanned linearly by the BLAS, so an unbounded list would
    hurt the hot path. Merging is conservative (the union's AABB is a superset),
    which over-occludes slightly rather than leaking light.
    """
    uniq: list[Box] = []
    for b in boxes:
        if b[0] >= b[3] or b[1] >= b[4] or b[2] >= b[5]:
            continue  # degenerate (zero-thickness) element
        contained = False
        for i, o in enumerate(uniq):
            if all(b[j] >= o[j] for j in range(3)) and all(b[j] <= o[j] for j in range(3, 6)):
                contained = True
                break
            if all(o[j] >= b[j] for j in range(3)) and all(o[j] <= b[j] for j in range(3, 6)):
                uniq[i] = b
                contained = True
                break
        if not contained:
            uniq.append(b)

    while len(uniq) > limit:
        best = None
        for i in range(len(uniq)):
            for j in range(i + 1, len(uniq)):
                a, b = uniq[i], uniq[j]
                u = (min(a[0], b[0]), min(a[1], b[1]), min(a[2], b[2]),
                     max(a[3], b[3]), max(a[4], b[4]), max(a[5], b[5]))
                vol = (u[3] - u[0]) * (u[4] - u[1]) * (u[5] - u[2])
                va = (a[3] - a[0]) * (a[4] - a[1]) * (a[5] - a[2])
                vb = (b[3] - b[0]) * (b[4] - b[1]) * (b[5] - b[2])
                waste = vol - va - vb
                if best is None or waste < best[0]:
                    best = (waste, i, j, u)
        _, i, j, u = best
        uniq = [u] + [b for k, b in enumerate(uniq) if k not in (i, j)]

    return uniq


# --------------------------------------------------------------------------
# blockstate enumeration
# --------------------------------------------------------------------------


def parse_variant_key(key: str) -> dict[str, str]:
    if not key:
        return {}
    out = {}
    for part in key.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def apply_entries(apply) -> list[dict]:
    """Normalise a variant/multipart 'apply' into a list of {model,x,y} dicts."""
    if isinstance(apply, list):
        return apply
    return [apply]


def model_refs(apply) -> list[tuple[str, int, int]]:
    """Extract (model_ref, x_rotation, y_rotation) from an apply clause.

    26.2 moved some blockstates onto a nested {"model": {"type": ..., "model": ...}}
    form; unwrap that so both layouts work.
    """
    out = []
    for entry in apply_entries(apply):
        if not isinstance(entry, dict):
            continue
        model = entry.get("model")
        while isinstance(model, dict):
            model = model.get("model") or model.get("models")
            if isinstance(model, list):
                model = model[0] if model else None
        if not isinstance(model, str):
            continue
        out.append((model, int(entry.get("x", 0)), int(entry.get("y", 0))))
        break  # weighted variants are alternatives; the first is representative
    return out


def condition_matches(cond: dict, state: dict[str, str]) -> bool:
    if "OR" in cond:
        return any(condition_matches(c, state) for c in cond["OR"])
    if "AND" in cond:
        return all(condition_matches(c, state) for c in cond["AND"])
    for key, want in cond.items():
        have = state.get(key)
        if have is None:
            return False
        if have not in str(want).split("|"):
            return False
    return True


def property_domain(observed: set[str]) -> set[str]:
    """Recover a property's full value domain from the values a multipart mentions.

    A multipart `when` only names the values that *add* geometry, so the default
    is silently absent: an oak_fence never says `north=false`, and a wall never
    says `north=none`. Taking the mentioned values at face value collapses every
    fence to the 4-way cross, which is exactly the connection-state bug this
    generator exists to fix. Infer the missing default from the value family.
    """
    vals = set(observed)
    if vals & {"low", "tall"}:          # wall side: none | low | tall
        vals.add("none")
    elif vals & {"side", "up"}:         # redstone wire side: none | side | up
        vals.add("none")
    elif vals <= {"true", "false"}:     # plain boolean connection/flag
        vals |= {"true", "false"}
    return vals


def multipart_properties(multipart: list) -> dict[str, set[str]]:
    """Collect every property mentioned by a multipart's conditions, with full domains."""
    props: dict[str, set[str]] = {}

    def walk(cond: dict):
        for key, val in cond.items():
            if key in ("OR", "AND"):
                for c in val:
                    walk(c)
                continue
            props.setdefault(key, set()).update(str(val).split("|"))

    for part in multipart:
        if "when" in part:
            walk(part["when"])
    return {k: property_domain(v) for k, v in props.items()}


def states_for_block(name: str, data: dict, assets: Assets, max_states: int):
    """Yield (state_dict, boxes) for each distinct blockstate of a block."""
    if "variants" in data:
        for key, apply in data["variants"].items():
            boxes: list[Box] = []
            for ref, rx, ry in model_refs(apply):
                for el in assets.elements(ref):
                    b = element_box(el)
                    if b is not None:
                        boxes.append(quantise(rotate_box(b, rx, ry)))
            yield parse_variant_key(key), boxes
        return

    multipart = data.get("multipart")
    if not multipart:
        return

    props = multipart_properties(multipart)
    # Enumerating the full product keeps connection state exact (this is what
    # makes a one-sided fence differ from a corner). Bail out to a conservative
    # union for anything pathologically large rather than emitting 10k shapes.
    total = 1
    for vals in props.values():
        total *= len(vals)
    if total > max_states:
        boxes = []
        for part in multipart:
            for ref, rx, ry in model_refs(part.get("apply", {})):
                for el in assets.elements(ref):
                    b = element_box(el)
                    if b is not None:
                        boxes.append(quantise(rotate_box(b, rx, ry)))
        yield {}, boxes
        return

    keys = sorted(props)
    for combo in itertools.product(*(sorted(props[k]) for k in keys)):
        state = dict(zip(keys, combo))
        boxes = []
        for part in multipart:
            when = part.get("when")
            if when and not condition_matches(when, state):
                continue
            for ref, rx, ry in model_refs(part.get("apply", {})):
                for el in assets.elements(ref):
                    b = element_box(el)
                    if b is not None:
                        boxes.append(quantise(rotate_box(b, rx, ry)))
        yield state, boxes


# --------------------------------------------------------------------------
# packing
# --------------------------------------------------------------------------


def pack_box(box: Box) -> tuple[int, int]:
    """Pack an AABB into two uints: 6 coords x 8 bits at 1/64-block precision.

    Layout matches unpackShapeBox() in lib/pt/blas.glsl:
        lo = xmin | ymin<<8 | zmin<<16 | xmax<<24
        hi = ymax | zmax<<8
    """
    xi, yi, zi, xa, ya, za = (int(v) & 0xFF for v in box)
    lo = xi | (yi << 8) | (zi << 16) | (xa << 24)
    hi = ya | (za << 8)
    return lo, hi


# --------------------------------------------------------------------------
# generation
# --------------------------------------------------------------------------


def build(assets: Assets, max_states: int, box_limit: int):
    shape_ids: dict[tuple, int] = {}     # box tuple -> shape id
    shape_boxes: list[list[Box]] = []    # shape id -> boxes
    entries: dict[int, list[str]] = {}   # mc_Entity id -> blockstate specs
    stats = {"blocks": 0, "states": 0, "full_cube": 0, "empty": 0, "skipped": 0}

    for name in sorted(assets.blockstates):
        if any(s in name for s in EXCLUDE_SUBSTRINGS):
            stats["skipped"] += 1
            continue
        if any(s in name for s in SKIP_SHAPE_SUBSTRINGS):
            stats["skipped"] += 1
            continue

        mat = classify_material(name)
        emitted_any = False

        for state, boxes in states_for_block(name, assets.blockstates[name], assets, max_states):
            stats["states"] += 1
            if not boxes:
                stats["empty"] += 1
                continue
            if is_full_cube(boxes):
                # A full cube needs no BLAS; the voxel itself is the occluder.
                stats["full_cube"] += 1
                continue

            merged = merge_boxes(boxes, box_limit)
            if not merged:
                stats["empty"] += 1
                continue

            key = tuple(sorted(merged))
            sid = shape_ids.get(key)
            if sid is None:
                sid = len(shape_boxes) + 1  # shape 0 reserved for "full cube"
                shape_ids[key] = sid
                shape_boxes.append(merged)

            block_id = SHAPE_ID_BASE + sid * (1 << MAT_BITS) + mat
            spec = name if not state else name + ":" + ":".join(
                f"{k}={v}" for k, v in sorted(state.items()))
            entries.setdefault(block_id, []).append(spec)
            emitted_any = True

        if emitted_any:
            stats["blocks"] += 1

    return shape_boxes, entries, stats


def render_block_properties(entries: dict[int, list[str]]) -> str:
    out = [
        GEN_BEGIN,
        "# Generated from Minecraft's own block models by scripts/gen_block_shapes.py.",
        "# Each id encodes shape and material as  40000 + shapeId*16 + matClass,",
        "# decoded in gbuffers/shadow.glsl (shape) and gbuffers/terrain.glsl (material).",
        "# Re-run the generator after a Minecraft version bump; do not hand-edit.",
        "",
    ]
    for block_id in sorted(entries):
        specs = sorted(entries[block_id])
        line = f"block.{block_id}="
        # Wrap with backslash continuations so lines stay readable in review.
        width = len(line)
        parts = []
        cur = line
        for spec in specs:
            if width + len(spec) + 1 > 200 and cur.strip() != line.strip():
                parts.append(cur + " \\")
                cur = "    " + spec
                width = len(cur)
            else:
                cur = cur + (" " if not cur.endswith("=") else "") + spec
                width += len(spec) + 1
        parts.append(cur)
        out.extend(parts)
    out.append(GEN_END)
    return "\n".join(out) + "\n"


def render_shape_table(shape_boxes: list[list[Box]]) -> str:
    offsets: list[tuple[int, int]] = []
    packed: list[tuple[int, int]] = []
    for boxes in shape_boxes:
        offsets.append((len(packed), len(boxes)))
        packed.extend(pack_box(b) for b in boxes)

    lines = [
        "#ifndef SHAPE_TABLE_GLSL",
        "#define SHAPE_TABLE_GLSL",
        "",
        "// Generated by scripts/gen_block_shapes.py from Minecraft's block models.",
        "// Included ONLY by the setup compute pass, which uploads it into the shape",
        "// SSBO once at pack load; the hot trace paths read the SSBO, never this file.",
        "",
        f"#define SHAPE_COUNT {len(shape_boxes)}u",
        f"#define SHAPE_BOX_COUNT {len(packed)}u",
        "",
        "// shapeId -> (boxOffset << 8) | boxCount   (shape 0 = full cube, no boxes)",
        f"const uint SHAPE_LOOKUP[{len(offsets) + 1}] = uint[{len(offsets) + 1}](",
        "    0u,  // shape 0: full cube",
    ]
    for i, (off, cnt) in enumerate(offsets):
        comma = "," if i < len(offsets) - 1 else ""
        lines.append(f"    {(off << 8) | cnt}u{comma}")
    lines.append(");")
    lines.append("")
    lines.append("// Packed AABBs, two uints each (see unpackShapeBox in lib/pt/blas.glsl).")
    lines.append(f"const uint SHAPE_BOXES[{len(packed) * 2}] = uint[{len(packed) * 2}](")
    flat = []
    for lo, hi in packed:
        flat.append(f"{lo}u")
        flat.append(f"{hi}u")
    for i in range(0, len(flat), 6):
        chunk = ", ".join(flat[i:i + 6])
        comma = "," if i + 6 < len(flat) else ""
        lines.append(f"    {chunk}{comma}")
    lines.append(");")
    lines.append("")
    lines.append("#endif")
    return "\n".join(lines) + "\n"


def splice_block_properties(existing: str, generated: str) -> str:
    if GEN_BEGIN in existing and GEN_END in existing:
        head = existing.split(GEN_BEGIN)[0]
        # `generated` already ends in a newline after GEN_END, so drop the ones
        # the previous splice left behind -- otherwise every run adds another and
        # --check reports drift forever against its own output.
        tail = existing.split(GEN_END, 1)[1].lstrip("\n")
        return head + generated + tail
    return existing.rstrip() + "\n\n" + generated


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jar", type=Path, default=None)
    ap.add_argument("--max-states", type=int, default=512,
                    help="per-block multipart state cap before falling back to a union")
    ap.add_argument("--box-limit", type=int, default=12,
                    help="max AABBs per shape; extras are conservatively merged")
    ap.add_argument("--check", action="store_true",
                    help="diff against committed files instead of writing")
    args = ap.parse_args()

    jar = args.jar or find_jar()
    print(f"minecraft jar : {jar}", file=sys.stderr)

    assets = Assets(jar)
    shape_boxes, entries, stats = build(assets, args.max_states, args.box_limit)

    bp_generated = render_block_properties(entries)
    table = render_shape_table(shape_boxes)

    print(
        f"blocks        : {stats['blocks']}\n"
        f"states seen   : {stats['states']}\n"
        f"  full cube   : {stats['full_cube']} (no shape needed)\n"
        f"  empty       : {stats['empty']}\n"
        f"blocks skipped: {stats['skipped']} (foliage/fluids/lights)\n"
        f"unique shapes : {len(shape_boxes)}\n"
        f"total boxes   : {sum(len(b) for b in shape_boxes)}\n"
        f"id entries    : {len(entries)}",
        file=sys.stderr,
    )

    existing = BLOCK_PROPERTIES.read_text(encoding="utf-8")
    spliced = splice_block_properties(existing, bp_generated)

    if args.check:
        drift = False
        if spliced != existing:
            print("block.properties is out of date", file=sys.stderr)
            drift = True
        if not SHAPE_TABLE.exists() or SHAPE_TABLE.read_text(encoding="utf-8") != table:
            print("shapeTable.glsl is out of date", file=sys.stderr)
            drift = True
        return 1 if drift else 0

    BLOCK_PROPERTIES.write_text(spliced, encoding="utf-8")
    SHAPE_TABLE.parent.mkdir(parents=True, exist_ok=True)
    SHAPE_TABLE.write_text(table, encoding="utf-8")
    print(f"wrote {BLOCK_PROPERTIES}\nwrote {SHAPE_TABLE}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
