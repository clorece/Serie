#ifndef VOXEL_DATA_GLSL
#define VOXEL_DATA_GLSL

#include "/lib/options.glsl"

// ============================================================================
//  SerieVX voxel grid — ANISOTROPIC, camera-relative, TRUE 3D TEXTURE
// ============================================================================
// The grid is wide in X/Z and short in Y (the Minecraft world is mostly
// horizontal) — see iterationRP's 512×128×512 voxelResolution.
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
// Dims must each be a multiple of VOXEL_BRICK (8) (and the X/Z a multiple of
// COARSE_ATLAS_COLS for the 2D coarse buffer). If you change them, update the
// X Y Z in the image.voxelImg directive + colortex4's resolution.
//
// ----------------------------------------------------------------------------
//  FUTURE WORK [SUBVOXELIZATION FOR NON-CUBE BLOCKS] (stairs/slabs/fences/etc).
//  Today every solid block is a full cube (category in .r). iterationRP stores
//  a per-voxel SHAPE ID (voxelID 25–78) and intersects the real block shape in
//  the voxel via HitShape_Lite() (a tiny SDF/AABB test per shape). To add: carry
//  a shape id per voxel (a spare channel of the RGBA8UI, or widen to a second
//  3D image), and in the DDA hit branch call HitShape(ray, voxelCoord, shapeId,
//  tHit) before accepting the hit. Cube fast-path stays for category==OPAQUE.
//  Brick-skip is unaffected (a brick is "occupied" if it has any non-air voxel).
// ============================================================================

#define VOXEL_DIM_X 512
#define VOXEL_DIM_Y 128
#define VOXEL_DIM_Z 512
const ivec3 VOXEL_DIMS       = ivec3(VOXEL_DIM_X, VOXEL_DIM_Y, VOXEL_DIM_Z);
// half-extent (radius) per axis; the camera sits at the grid centre
const vec3  VOXEL_RADIUS_VEC = vec3(VOXEL_DIM_X / 2, VOXEL_DIM_Y / 2, VOXEL_DIM_Z / 2);

// block categories stored in the voxel grid (.r channel of each RGBA8UI texel)
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u


// --- Coarse occupancy (brick-skipping DDA acceleration) ---
// Stays a small 2D atlas (colortex4) — it's tiny (64×16×64 cells) and fits the
// render resolution easily, so it doesn't hit the image-buffer size limit.
// One coarse cell ("brick") = VOXEL_BRICK³ voxels of the fine atlas. A brick is
// "occupied" iff any voxel inside it is non-air. Built every frame in prepare2
// (program/prepare/p2_voxel_mip.glsl) into colortex4, then used by the DDA in
// ddaTrace.glsl / gi.glsl to skip whole empty bricks in one step.
#define VOXEL_BRICK 8
const ivec3 COARSE_DIMS = ivec3(VOXEL_DIM_X / VOXEL_BRICK, VOXEL_DIM_Y / VOXEL_BRICK, VOXEL_DIM_Z / VOXEL_BRICK); // 64×16×64
#define COARSE_ATLAS_COLS 8
// coarse atlas: width = 8·64 = 512, height = (64/8)·16 = 128  →  colortex4 ≥ 512×128

ivec2 coarseCoordToAtlas(ivec3 c) {
    int col = c.z % COARSE_ATLAS_COLS;
    int row = c.z / COARSE_ATLAS_COLS;
    return ivec2(col * COARSE_DIMS.x + c.x, row * COARSE_DIMS.y + c.y);
}

// Inverse of coarseCoordToAtlas — used by the prepare2 build pass to turn the
// fragment's pixel coordinate back into the coarse cell it represents. Returns
// false for atlas texels that fall outside the valid coarse grid.
bool coarseAtlasToCoord(ivec2 px, out ivec3 c) {
    int col = px.x / COARSE_DIMS.x;
    int cx  = px.x % COARSE_DIMS.x;
    int row = px.y / COARSE_DIMS.y;
    int cy  = px.y % COARSE_DIMS.y;
    int cz  = row * COARSE_ATLAS_COLS + col;
    c = ivec3(cx, cy, cz);
    return (col < COARSE_ATLAS_COLS) && (cz < COARSE_DIMS.z);
}

// True when the brick containing fine voxel `vox` is provably empty (safe to
// skip). Returns false at/outside grid bounds so the caller falls back to a
// normal fine step there. Occupancy is stored as 0.0/1.0 in colortex4.r.
bool brickIsEmpty(sampler2D coarse, ivec3 vox) {
    if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, VOXEL_DIMS))) return false;
    ivec3 brick = vox >> 3; // /VOXEL_BRICK (8)
    return texelFetch(coarse, coarseCoordToAtlas(brick), 0).r < 0.5;
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
