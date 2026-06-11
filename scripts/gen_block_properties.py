#!/usr/bin/env python3
"""Generates the 'voxel shapes' (block.20xxx) section of SerieVX block.properties.

Shape id enum mirrors shaders/lib/pt/voxelData.glsl:
  1..15  bottom box h=N/16      16+N  top box h=N/16
  31..34 wall plane N/S/W/E     35/36 centered wall along X / Z
  37 fence cross  38 pane cross  39 wall cross
  40 post  41 small box  42 thin column
  43..66 stairs (43 + group*8 + top*4 + orient)
Block id = 20000 + shape id.
"""

WOODS = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove",
         "cherry", "pale_oak", "bamboo", "crimson", "warped"]

SLABS = [w + "_slab" for w in WOODS] + ["bamboo_mosaic_slab"] + [
    "stone_slab", "smooth_stone_slab", "cobblestone_slab", "mossy_cobblestone_slab",
    "stone_brick_slab", "mossy_stone_brick_slab", "granite_slab", "diorite_slab",
    "andesite_slab", "polished_granite_slab", "polished_diorite_slab", "polished_andesite_slab",
    "mud_brick_slab", "brick_slab", "cobbled_deepslate_slab", "polished_deepslate_slab",
    "deepslate_brick_slab", "deepslate_tile_slab",
    "sandstone_slab", "cut_sandstone_slab", "smooth_sandstone_slab",
    "red_sandstone_slab", "cut_red_sandstone_slab", "smooth_red_sandstone_slab",
    "cut_copper_slab", "exposed_cut_copper_slab", "weathered_cut_copper_slab",
    "oxidized_cut_copper_slab", "waxed_cut_copper_slab", "waxed_exposed_cut_copper_slab",
    "waxed_weathered_cut_copper_slab", "waxed_oxidized_cut_copper_slab",
    "quartz_slab", "smooth_quartz_slab", "purpur_slab",
    "nether_brick_slab", "red_nether_brick_slab", "end_stone_brick_slab",
    "prismarine_slab", "prismarine_brick_slab", "dark_prismarine_slab",
    "blackstone_slab", "polished_blackstone_slab", "polished_blackstone_brick_slab",
    "tuff_slab", "polished_tuff_slab", "tuff_brick_slab", "resin_brick_slab",
    "petrified_oak_slab",
]

STAIRS = [w + "_stairs" for w in WOODS] + ["bamboo_mosaic_stairs"] + [
    "stone_stairs", "cobblestone_stairs", "mossy_cobblestone_stairs",
    "stone_brick_stairs", "mossy_stone_brick_stairs", "granite_stairs", "diorite_stairs",
    "andesite_stairs", "polished_granite_stairs", "polished_diorite_stairs", "polished_andesite_stairs",
    "mud_brick_stairs", "brick_stairs", "cobbled_deepslate_stairs", "polished_deepslate_stairs",
    "deepslate_brick_stairs", "deepslate_tile_stairs",
    "sandstone_stairs", "smooth_sandstone_stairs",
    "red_sandstone_stairs", "smooth_red_sandstone_stairs",
    "cut_copper_stairs", "exposed_cut_copper_stairs", "weathered_cut_copper_stairs",
    "oxidized_cut_copper_stairs", "waxed_cut_copper_stairs", "waxed_exposed_cut_copper_stairs",
    "waxed_weathered_cut_copper_stairs", "waxed_oxidized_cut_copper_stairs",
    "quartz_stairs", "smooth_quartz_stairs", "purpur_stairs",
    "nether_brick_stairs", "red_nether_brick_stairs", "end_stone_brick_stairs",
    "prismarine_stairs", "prismarine_brick_stairs", "dark_prismarine_stairs",
    "blackstone_stairs", "polished_blackstone_stairs", "polished_blackstone_brick_stairs",
    "tuff_stairs", "polished_tuff_stairs", "tuff_brick_stairs", "resin_brick_stairs",
]

TRAPDOORS = [w + "_trapdoor" for w in WOODS] + [
    "iron_trapdoor", "copper_trapdoor", "exposed_copper_trapdoor", "weathered_copper_trapdoor",
    "oxidized_copper_trapdoor", "waxed_copper_trapdoor", "waxed_exposed_copper_trapdoor",
    "waxed_weathered_copper_trapdoor", "waxed_oxidized_copper_trapdoor",
]

DOORS = [w + "_door" for w in WOODS] + [
    "iron_door", "copper_door", "exposed_copper_door", "weathered_copper_door",
    "oxidized_copper_door", "waxed_copper_door", "waxed_exposed_copper_door",
    "waxed_weathered_copper_door", "waxed_oxidized_copper_door",
]

FENCES = [w + "_fence" for w in WOODS] + ["nether_brick_fence"]
GATES  = [w + "_fence_gate" for w in WOODS]

WALLS = ["cobblestone_wall", "mossy_cobblestone_wall", "stone_brick_wall", "mossy_stone_brick_wall",
         "granite_wall", "diorite_wall", "andesite_wall", "mud_brick_wall", "brick_wall",
         "cobbled_deepslate_wall", "polished_deepslate_wall", "deepslate_brick_wall", "deepslate_tile_wall",
         "sandstone_wall", "red_sandstone_wall", "nether_brick_wall", "red_nether_brick_wall",
         "end_stone_brick_wall", "prismarine_wall", "blackstone_wall", "polished_blackstone_wall",
         "polished_blackstone_brick_wall", "tuff_wall", "polished_tuff_wall", "tuff_brick_wall",
         "resin_brick_wall"]

COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
          "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]

CARPETS = [c + "_carpet" for c in COLORS] + ["moss_carpet", "pale_moss_carpet"]
BEDS    = [c + "_bed" for c in COLORS]
PRESSURE_PLATES = [w + "_pressure_plate" for w in WOODS] + [
    "stone_pressure_plate", "polished_blackstone_pressure_plate",
    "light_weighted_pressure_plate", "heavy_weighted_pressure_plate"]
UNLIT_CANDLES = ["candle:lit=false"] + [c + "_candle:lit=false" for c in COLORS]

POTTED = ["flower_pot", "decorated_pot"] + ["potted_" + p for p in [
    "dandelion", "poppy", "blue_orchid", "allium", "azure_bluet", "red_tulip", "orange_tulip",
    "white_tulip", "pink_tulip", "oxeye_daisy", "cornflower", "lily_of_the_valley", "wither_rose",
    "oak_sapling", "spruce_sapling", "birch_sapling", "jungle_sapling", "acacia_sapling",
    "dark_oak_sapling", "cherry_sapling", "pale_oak_sapling", "mangrove_propagule", "bamboo",
    "azalea_bush", "flowering_azalea_bush", "fern", "dead_bush", "cactus",
    "brown_mushroom", "red_mushroom", "crimson_roots", "warped_roots", "crimson_fungus",
    "warped_fungus", "torchflower", "closed_eyeblossom"]]

lines = {}   # block id -> list of entries
def add(bid, entries):
    lines.setdefault(bid, []).extend(entries)

# --- bottom boxes ---------------------------------------------------------
add(20001, CARPETS + PRESSURE_PLATES)
add(20002, ["snow:layers=1", "repeater:powered=false", "unpowered_repeater",
            "comparator:mode=compare:powered=false", "unpowered_comparator"])
add(20003, [t + ":half=bottom:open=false" for t in TRAPDOORS])
add(20004, ["snow:layers=2", "snow_layer"])
add(20006, ["snow:layers=3", "daylight_detector"])
add(20007, ["campfire:lit=false", "soul_campfire:lit=false"])
add(20008, ["snow:layers=4", "cake"] + [c + "_candle_cake:lit=false" for c in COLORS]
           + ["candle_cake:lit=false"]
           + [s + ":type=bottom" for s in SLABS] + ["wooden_slab", "stone_slab2"])
add(20009, ["snow:layers=5", "stonecutter"] + BEDS)
add(20012, ["snow:layers=6", "hopper", "composter",
            "anvil", "chipped_anvil", "damaged_anvil", "grindstone", "end_portal_frame:eye=false"])
add(20014, ["snow:layers=7", "lectern", "chest", "trapped_chest", "ender_chest"])
add(20015, ["dirt_path", "grass_path", "farmland", "cauldron", "water_cauldron",
            "powder_snow_cauldron"])

# --- top boxes ------------------------------------------------------------
add(20018, ["scaffolding"])
add(20019, [t + ":half=top:open=false" for t in TRAPDOORS])
add(20024, [s + ":type=top" for s in SLABS])

# --- wall planes (31 N / 32 S / 33 W / 34 E) ------------------------------
# doors: vanilla model sits on the WEST edge at facing=east (y-rot 0);
# open swings around the hinge. Ladders / open trapdoors rest against the
# edge opposite their facing.
door_map = {  # facing -> (closed, open_hinge_left, open_hinge_right)
    "east":  (33, 31, 32),
    "south": (31, 34, 33),
    "west":  (34, 32, 31),
    "north": (32, 33, 34),
}
for facing, (closed, oleft, oright) in door_map.items():
    add(20000 + closed, [d + f":facing={facing}:open=false" for d in DOORS])
    add(20000 + oleft,  [d + f":facing={facing}:open=true:hinge=left"  for d in DOORS])
    add(20000 + oright, [d + f":facing={facing}:open=true:hinge=right" for d in DOORS])
opposite = {"north": 32, "south": 31, "west": 34, "east": 33}
for facing, shape in opposite.items():
    add(20000 + shape, ["ladder:facing=" + facing]
                       + [t + f":facing={facing}:open=true" for t in TRAPDOORS])

# --- centered walls / crosses / small shapes ------------------------------
add(20035, [g + f":facing={f}:open=false" for g in GATES for f in ("north", "south")])
add(20036, [g + f":facing={f}:open=false" for g in GATES for f in ("east", "west")])
add(20037, FENCES)
add(20038, ["iron_bars"])
add(20039, WALLS)
add(20041, POTTED + UNLIT_CANDLES + ["turtle_egg", "sniffer_egg", "conduit", "heavy_core"])
add(20042, ["chain", "lightning_rod", "pointed_dripstone", "bamboo"])

# --- stairs ----------------------------------------------------------------
# straight: shape 43 + (top?4:0) + orient, orient = riser side N0 S1 W2 E3
straight_orient = {"north": 0, "south": 1, "west": 2, "east": 3}
for facing, o in straight_orient.items():
    for half, topoff in (("bottom", 0), ("top", 4)):
        add(20043 + topoff + o,
            [s + f":facing={facing}:half={half}:shape=straight" for s in STAIRS])

# corners: quadrant NW0 NE1 SW2 SE3 from (facing, left/right) — same relation
# for outer (group 1, base 51) and inner (group 2, base 59)
corner_quad = {("north", "left"): 0, ("north", "right"): 1,
               ("east",  "left"): 1, ("east",  "right"): 3,
               ("south", "left"): 3, ("south", "right"): 2,
               ("west",  "left"): 2, ("west",  "right"): 0}
for (facing, side), q in corner_quad.items():
    for half, topoff in (("bottom", 0), ("top", 4)):
        add(20051 + topoff + q,
            [s + f":facing={facing}:half={half}:shape=outer_{side}" for s in STAIRS])
        add(20059 + topoff + q,
            [s + f":facing={facing}:half={half}:shape=inner_{side}" for s in STAIRS])

# --- emit -------------------------------------------------------------------
SHAPE_DESC = {
    20001: "1/16 floor box: carpets, pressure plates",
    20002: "2/16 floor box: snow (1 layer), unpowered repeater/comparator",
    20003: "3/16 floor box: closed bottom trapdoors",
    20004: "4/16 floor box: snow (2 layers)",
    20006: "6/16 floor box: snow (3 layers), daylight detector",
    20007: "7/16 floor box: unlit campfires",
    20008: "8/16 floor box: bottom slabs, cake, snow (4 layers)",
    20009: "9/16 floor box: beds, stonecutter, snow (5 layers)",
    20012: "12/16 floor box: hopper, composter, anvils, grindstone, snow (6 layers)",
    20014: "14/16 floor box: chests, lectern, snow (7 layers)",
    20015: "15/16 floor box: dirt path, farmland, cauldrons",
    20018: "2/16 ceiling box: scaffolding platform",
    20019: "3/16 ceiling box: closed top trapdoors",
    20024: "8/16 ceiling box: top slabs",
    20031: "wall plane against NORTH face: doors/ladders/open trapdoors",
    20032: "wall plane against SOUTH face",
    20033: "wall plane against WEST face",
    20034: "wall plane against EAST face",
    20035: "centered wall running E-W: closed gates facing N/S",
    20036: "centered wall running N-S: closed gates facing E/W",
    20037: "fence cross (post + arms approximation)",
    20038: "pane cross: iron bars",
    20039: "wall cross: walls",
    20041: "small centered box: flower pots, unlit candles, eggs, conduit",
    20042: "thin column: chain, lightning rod, dripstone, bamboo",
}
STAIR_DESC = {
    0: ("straight", ["riser N", "riser S", "riser W", "riser E"]),
    1: ("outer corner", ["quarter NW", "quarter NE", "quarter SW", "quarter SE"]),
    2: ("inner corner", ["L wraps NW", "L wraps NE", "L wraps SW", "L wraps SE"]),
}

out = []
for bid in sorted(lines):
    entries = lines[bid]
    assert len(entries) == len(set(entries)), f"dup in {bid}"
    if bid in SHAPE_DESC:
        out.append(f"# shape {bid-20000}: {SHAPE_DESC[bid]}")
    else:
        s = bid - 20000 - 43
        grp, orients = STAIR_DESC[s >> 3]
        half = "top" if s & 4 else "bottom"
        out.append(f"# shape {bid-20000}: stairs {grp}, {half} half, {orients[s & 3]}")
    body = " \\\n".join(
        "            " + " ".join(entries[i:i+6]) for i in range(0, len(entries), 6))
    out.append(f"block.{bid}=\\\n{body}")
    out.append("")

text = "\n".join(out)
with open("/home/clorece/.claude/jobs/43d3f449/tmp/shaped_section.properties", "w") as f:
    f.write(text)
print(f"{len(lines)} block ids, {sum(len(v) for v in lines.values())} entries, {len(text)} bytes")
