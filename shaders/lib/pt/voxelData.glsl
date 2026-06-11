#ifndef VOXEL_DATA_GLSL
#define VOXEL_DATA_GLSL

#include "/lib/options.glsl"

// ============================================================================
//  SerieVX voxel grid — ANISOTROPIC, camera-relative, TRUE 3D TEXTURE
// ============================================================================
// The grid is wide in X/Z and short in Y (the Minecraft world is mostly
// horizontal).
//
//   512 × 128 × 512  → horizontal radius 256, vertical radius 64.
//
// Stored in a DEDICATED 3D image `voxelImg` / read via `voxelSampler`
// (declared by `image.voxelImg = ...` in shaders.properties). Direct ivec3
// addressing — no 2D-atlas packing. We moved here from the old colortex7 2D
// atlas because Iris would not allocate that atlas larger than ~4096 / the
// render resolution for an image-bound colortex, which capped the grid and
// shifted it off-centre. A 3D image takes explicit dims (up to
// GL_MAX_3D_TEXTURE_SIZE, ~2048) and is also better for DDA cache locality.
//
// Dims must each be a multiple of VOXEL_SUPER (64). If you change them, update
// the X Y Z of image.voxelImg, image.brickImg (dims/8) and image.superBrickImg
// (dims/64) in shaders.properties.
//
// ----------------------------------------------------------------------------
//  SUB-BLOCK SHAPES (stairs/slabs/fences/doors/torches/etc) — VOXEL_SHAPES.
//  The shape id is packed INTO the category byte (.r): categories
//  [VOXEL_SHAPED_BASE .. VOXEL_SHAPED_BASE+VOXEL_SHAPE_MAX] mean "opaque block
//  whose geometry is shapeId = category - VOXEL_SHAPED_BASE" (albedo stays in
//  .gba untouched, no extra image / no extra fetch in the DDA). Blocklights
//  (category 100+mat) derive their shape from the material id at trace time
//  (lightVoxelShape) for free. On a DDA hit candidate the tracers call
//  intersectVoxelShape(): 1-3 AABB slab tests inside the voxel; a miss lets
//  the ray continue marching. Full cubes keep the branchless fast path.
//  Brick-skip is unaffected (a brick is "occupied" if it has any non-air voxel).
//  block.properties side: block id 20000+N maps to shapeId N (pure arithmetic
//  in shadow.vsh) — see the "voxel shapes" section there.
// ============================================================================

// X/Z scale with the VOXEL_DISTANCE option (chunks of horizontal radius):
// dim = radius*2 = chunks*16*2. All option values keep dims a multiple of
// VOXEL_SUPER (64). The image dims in shaders.properties follow via its own
// #if VOXEL_DISTANCE chain — keep them in sync.
#define VOXEL_DIM_X (VOXEL_DISTANCE * 32)
#define VOXEL_DIM_Y 128
#define VOXEL_DIM_Z (VOXEL_DISTANCE * 32)
const ivec3 VOXEL_DIMS       = ivec3(VOXEL_DIM_X, VOXEL_DIM_Y, VOXEL_DIM_Z);
// half-extent (radius) per axis; the camera sits at the grid centre
const vec3  VOXEL_RADIUS_VEC = vec3(VOXEL_DIM_X / 2, VOXEL_DIM_Y / 2, VOXEL_DIM_Z / 2);

// block categories stored in the voxel grid (.r channel of each RGBA8UI texel)
// 0-3 = simple categories, [4..70] = opaque with sub-block shape (shape id =
// category - VOXEL_SHAPED_BASE), 100+ = special blocklight (100 + mat).
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u
#define VOXEL_SHAPED_BASE 4u
#define VOXEL_SHAPE_MAX   66u

// ----------------------------------------------------------------------------
// Shape id enum (block.properties id = 20000 + shapeId):
//   0        full cube (never stored as shaped)
//   1..15    bottom-aligned full-footprint box, height N/16
//            (1 carpet/pressure plate, 2 repeater, 3 bottom trapdoor,
//             7 campfire, 8 bottom slab/cake, 9 bed/stonecutter, 12 enchanting
//             table/hopper, 14 chest/lectern, 15 dirt path/cauldron, ...)
//   16+N     top-aligned box, height N/16 (N=1..15: 19 top trapdoor,
//            24 top slab, 18 scaffolding platform, ...)
//   31..34   wall plane pressed against the N/S/W/E face, 3/16 thick
//            (doors, ladders, open trapdoors)
//   35       centered wall running X (east-west, 4/16 thick: gates facing N/S)
//   36       centered wall running Z (north-south: gates facing E/W)
//   37       fence cross (two crossing 4/16 walls, full height)
//   38       pane cross  (two crossing 2/16 walls, full height: iron bars)
//   39       wall cross  (two crossing 8/16 walls, 14/16 tall)
//   40       center post (torch:  4/16 sq, 10/16 tall)
//   41       small centered box (lantern/candles/pots: 6/16 sq, 9/16 tall)
//   42       thin column (chain/end rod/dripstone/bamboo: 2/16 sq, full height)
//   43..66   stairs: 43 + group*8 + (half==top ? 4 : 0) + orient
//            group 0 straight: orient 0..3 = riser on N,S,W,E half
//            group 1 outer:    orient 0..3 = quarter-riser in NW,NE,SW,SE
//            group 2 inner:    orient 0..3 = L-riser wrapping NW,NE,SW,SE
//            (north = -Z, west = -X; "riser" = the half-height step part,
//             the slab part is implied by half)
// ----------------------------------------------------------------------------

// Shapes for special blocklights (category 100+mat), derived from the light
// material — no storage needed. mat numbers follow block.properties 101xx ids.
uint lightVoxelShape(uint mat) {
    if (mat ==  2u || mat == 28u || mat == 35u) return 40u; // torch / soul / redstone torch
    if (mat == 12u || mat == 29u || mat ==  6u || mat == 36u ||
        mat == 38u || mat == 40u || mat == 24u ||
        (mat >= 70u && mat <= 80u))             return 41u; // lanterns, sea pickle, amethyst, dragon egg, brewing stand, candles
    if (mat ==  3u || mat == 20u || mat == 65u) return 42u; // end rod, cave/weeping/twisting vines
    if (mat == 15u || mat == 30u)               return  7u; // campfires
    if (mat == 33u)                             return 12u; // enchanting table
    if (mat == 66u)                             return  1u; // redstone wire
    if (mat == 67u)                             return  2u; // powered repeater/comparator
    return 0u;
}

uint voxelShapeId(uint cat) {
    if (cat >= VOXEL_SHAPED_BASE && cat <= VOXEL_SHAPED_BASE + VOXEL_SHAPE_MAX)
        return cat - VOXEL_SHAPED_BASE;
    if (cat >= 100u) return lightVoxelShape(cat - 100u);
    return 0u;
}

// Ray vs AABB inside one voxel. `ro` = ray origin relative to the voxel min
// corner, `ird` = 1/rayDir. Keeps the nearest hit in tBest/nBest. An origin
// inside the box counts as a t=0 hit (nBest keeps its fallback value then).
bool voxelAabbHit(vec3 ro, vec3 ird, vec3 bmin, vec3 bmax, inout float tBest, inout vec3 nBest) {
    vec3 t0  = (bmin - ro) * ird;
    vec3 t1  = (bmax - ro) * ird;
    vec3 tn3 = min(t0, t1);
    vec3 tf3 = max(t0, t1);
    float tn = max(tn3.x, max(tn3.y, tn3.z));
    float tf = min(tf3.x, min(tf3.y, tf3.z));
    if (tn > tf || tf < 0.0) return false;
    float t = max(tn, 0.0);
    if (t >= tBest) return false;
    tBest = t;
    if (tn > 0.0) nBest = -sign(ird) * vec3(equal(vec3(tn), tn3));
    return true;
}

// Intersect the ray with the sub-block shape of one voxel. `ro` is the ray
// origin RELATIVE to the voxel min corner (localPos - vec3(vox)); shapes are
// unions of 1-3 AABBs built procedurally (no LUTs). Returns the nearest hit.
bool intersectVoxelShape(uint shape, vec3 ro, vec3 rd, out float tHit, out vec3 nHit) {
    vec3 ird = 1.0 / (rd + vec3(1e-8));
    tHit = 1e30;
    nHit = -rd; // fallback normal when the ray starts inside the shape
    bool hit = false;

    if (shape <= 30u) {
        // bottom- (1..15) or top- (17..31, bit 4) aligned full-footprint box
        float h  = float(shape & 15u) * (1.0 / 16.0);
        bool  ta = shape > 16u;
        hit = voxelAabbHit(ro, ird, vec3(0.0, ta ? 1.0 - h : 0.0, 0.0),
                                    vec3(1.0, ta ? 1.0 : h,       1.0), tHit, nHit);
    } else if (shape <= 34u) {
        // 3/16 wall plane against the N/S/W/E face
        const float T = 3.0 / 16.0;
        vec3 bmin = vec3(0.0), bmax = vec3(1.0);
        if      (shape == 31u) bmax.z = T;
        else if (shape == 32u) bmin.z = 1.0 - T;
        else if (shape == 33u) bmax.x = T;
        else                   bmin.x = 1.0 - T;
        hit = voxelAabbHit(ro, ird, bmin, bmax, tHit, nHit);
    } else if (shape <= 36u) {
        // centered 4/16 wall running X (35) or Z (36) — closed fence gates
        const float T = 2.0 / 16.0;
        vec3 bmin = vec3(0.0), bmax = vec3(1.0);
        if (shape == 35u) { bmin.z = 0.5 - T; bmax.z = 0.5 + T; }
        else              { bmin.x = 0.5 - T; bmax.x = 0.5 + T; }
        hit = voxelAabbHit(ro, ird, bmin, bmax, tHit, nHit);
    } else if (shape <= 39u) {
        // two crossing centered walls: fence (4/16), pane/bars (2/16), wall (8/16)
        float T  = (shape == 37u) ? 2.0 / 16.0 : (shape == 38u) ? 1.0 / 16.0 : 4.0 / 16.0;
        float H  = (shape == 39u) ? 14.0 / 16.0 : 1.0;
        float lo = 0.5 - T, hi = 0.5 + T;
        hit = voxelAabbHit(ro, ird, vec3(lo, 0.0, 0.0), vec3(hi, H, 1.0), tHit, nHit);
        hit = voxelAabbHit(ro, ird, vec3(0.0, 0.0, lo), vec3(1.0, H, hi), tHit, nHit) || hit;
    } else if (shape <= 42u) {
        // centered boxes: 40 torch post, 41 small box, 42 thin full-height column
        float W = (shape == 40u) ? 2.0 / 16.0 : (shape == 41u) ? 3.0 / 16.0 : 1.0 / 16.0;
        float H = (shape == 40u) ? 10.0 / 16.0 : (shape == 41u) ? 9.0 / 16.0 : 1.0;
        hit = voxelAabbHit(ro, ird, vec3(0.5 - W, 0.0, 0.5 - W),
                                    vec3(0.5 + W, H,   0.5 + W), tHit, nHit);
    } else {
        // stairs: slab half + riser (straight half / outer quarter / inner L)
        uint  s     = shape - 43u;
        uint  group = s >> 3;
        bool  top   = (s & 4u) != 0u;
        uint  o     = s & 3u;
        float sy0   = top ? 0.5 : 0.0; // slab part y-min
        float ry0   = 0.5 - sy0;       // riser part y-min (the other half)
        hit = voxelAabbHit(ro, ird, vec3(0.0, sy0, 0.0), vec3(1.0, sy0 + 0.5, 1.0), tHit, nHit);
        if (group == 0u) {
            vec2 xr = vec2(0.0, 1.0), zr = vec2(0.0, 1.0);
            if      (o == 0u) zr = vec2(0.0, 0.5);
            else if (o == 1u) zr = vec2(0.5, 1.0);
            else if (o == 2u) xr = vec2(0.0, 0.5);
            else              xr = vec2(0.5, 1.0);
            hit = voxelAabbHit(ro, ird, vec3(xr.x, ry0, zr.x), vec3(xr.y, ry0 + 0.5, zr.y), tHit, nHit) || hit;
        } else {
            vec2 qx = (o & 1u) == 0u ? vec2(0.0, 0.5) : vec2(0.5, 1.0); // W/E half
            vec2 qz = (o & 2u) == 0u ? vec2(0.0, 0.5) : vec2(0.5, 1.0); // N/S half
            if (group == 1u) {
                hit = voxelAabbHit(ro, ird, vec3(qx.x, ry0, qz.x), vec3(qx.y, ry0 + 0.5, qz.y), tHit, nHit) || hit;
            } else {
                hit = voxelAabbHit(ro, ird, vec3(qx.x, ry0, 0.0), vec3(qx.y, ry0 + 0.5, 1.0), tHit, nHit) || hit;
                hit = voxelAabbHit(ro, ird, vec3(0.0, ry0, qz.x), vec3(1.0, ry0 + 0.5, qz.y), tHit, nHit) || hit;
            }
        }
    }
    return hit;
}


// --- Hierarchical occupancy (empty-space-skipping DDA acceleration) ---
// TWO levels of occupancy, both dedicated 3D images written DURING
// voxelization (the shadow pass stores 1 into both alongside every fine voxel
// write — see program/gbuffers/shadow.glsl). This replaced the old prepare2
// reduction pass, which re-read up to 8³ fine voxels for every one of the
// 64×16×64 coarse cells every frame (tens of millions of texelFetches/frame,
// dominated by fully-empty bricks that could never early-out).
//
//   level 0: "brick"       =  8³ blocks  → brickImg/brickSampler,      64×16×64 R8UI
//   level 1: "super-brick" = 64³ blocks  → superBrickImg/superBrickSampler, 8×2×8 R8UI
//
// A cell is "occupied" iff any fine voxel inside it was written this frame
// (exactly the same predicate the old reduction computed). Both images are
// cleared each frame by Iris (clear=true in shaders.properties), so racing
// imageStores of the constant 1 are benign.
#define VOXEL_BRICK 8
#define VOXEL_SUPER 64
const ivec3 BRICK_DIMS = VOXEL_DIMS / VOXEL_BRICK; // 64×16×64
const ivec3 SUPER_DIMS = VOXEL_DIMS / VOXEL_SUPER; // 8×2×8

// True when the 8³ brick containing fine voxel `vox` is provably empty (safe
// to skip). Returns false at/outside grid bounds so the caller falls back to a
// normal fine step there.
bool brickIsEmpty(ivec3 vox) {
    if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, VOXEL_DIMS))) return false;
    return texelFetch(brickSampler, vox >> 3, 0).r == 0u;
}

// True when the 64³ super-brick containing fine voxel `vox` is provably empty.
// Lets open-air rays jump ~64 blocks in one step before descending to the
// brick level and finally the fine DDA near geometry.
bool superBrickIsEmpty(ivec3 vox) {
    if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, VOXEL_DIMS))) return false;
    return texelFetch(superBrickSampler, vox >> 6, 0).r == 0u;
}


bool worldToVoxel(vec3 worldPos, vec3 gridOrigin, out ivec3 coord) {
    vec3 local = worldPos - gridOrigin;
    coord = ivec3(floor(local));
    return all(greaterThanEqual(coord, ivec3(0))) &&
           all(lessThan(coord, VOXEL_DIMS));
}


// Fine voxel read — direct 3D addressing into the dedicated voxel image.
uint sampleVoxel(usampler3D atlas, ivec3 coord) {
    return texelFetch(atlas, coord, 0).r;
}


struct VoxelSample {
    uint category;
    vec3 albedo;
};

VoxelSample readVoxel(usampler3D atlas, ivec3 coord) {
    uvec4 v = texelFetch(atlas, coord, 0);
    VoxelSample s;
    s.category = v.r;
    s.albedo   = vec3(v.gba) / 255.0;
    return s;
}

#endif
