#ifndef VOXEL_DATA_GLSL
#define VOXEL_DATA_GLSL

#include "/lib/options.glsl"

#define VOXEL_RADIUS 64

#if VOXEL_GRID_SIZE <= 64
    #define VOXEL_ATLAS_COLS 8
#elif VOXEL_GRID_SIZE <= 512
    #define VOXEL_ATLAS_COLS 16
#else
    #define VOXEL_ATLAS_COLS 32
#endif

#define VOXEL_ATLAS_ROWS (VOXEL_GRID_SIZE / VOXEL_ATLAS_COLS)

// block categories stored in voxel atlas (.r channel of each RGBA8UI texel)
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u


ivec2 voxelCoordToAtlas(ivec3 c) {
    int col = c.z % VOXEL_ATLAS_COLS;
    int row = c.z / VOXEL_ATLAS_COLS;
    return ivec2(col * VOXEL_GRID_SIZE + c.x, row * VOXEL_GRID_SIZE + c.y);
}


// --- Coarse occupancy pyramid (brick-skipping DDA acceleration) ---
// One coarse cell ("brick") = VOXEL_BRICK³ voxels of the fine atlas. A brick is
// "occupied" iff any voxel inside it is non-air. Built every frame in prepare2
// (program/prepare/p2_voxel_mip.glsl) into colortex4, then used by the DDA in
// ddaTrace.glsl / gi.glsl to skip whole empty bricks in one step.
#define VOXEL_BRICK 8
#define COARSE_GRID_SIZE (VOXEL_GRID_SIZE / VOXEL_BRICK)
#define COARSE_ATLAS_COLS 8

ivec2 coarseCoordToAtlas(ivec3 c) {
    int col = c.z % COARSE_ATLAS_COLS;
    int row = c.z / COARSE_ATLAS_COLS;
    return ivec2(col * COARSE_GRID_SIZE + c.x, row * COARSE_GRID_SIZE + c.y);
}

// Inverse of coarseCoordToAtlas — used by the prepare2 build pass to turn the
// fragment's pixel coordinate back into the coarse cell it represents. Returns
// false for atlas texels that fall outside the valid coarse grid.
bool coarseAtlasToCoord(ivec2 px, out ivec3 c) {
    int col = px.x / COARSE_GRID_SIZE;
    int cx  = px.x % COARSE_GRID_SIZE;
    int row = px.y / COARSE_GRID_SIZE;
    int cy  = px.y % COARSE_GRID_SIZE;
    int cz  = row * COARSE_ATLAS_COLS + col;
    c = ivec3(cx, cy, cz);
    return (col < COARSE_ATLAS_COLS) && (cz < COARSE_GRID_SIZE);
}

// True when the brick containing fine voxel `vox` is provably empty (safe to
// skip). Returns false at/outside grid bounds so the caller falls back to a
// normal fine step there. Occupancy is stored as 0.0/1.0 in colortex4.r.
bool brickIsEmpty(sampler2D coarse, ivec3 vox) {
    if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(VOXEL_GRID_SIZE)))) return false;
    ivec3 brick = vox >> 3; // /VOXEL_BRICK (8)
    return texelFetch(coarse, coarseCoordToAtlas(brick), 0).r < 0.5;
}


bool worldToVoxel(vec3 worldPos, vec3 gridOrigin, out ivec3 coord) {
    vec3 local = worldPos - gridOrigin;
    coord = ivec3(floor(local));
    return all(greaterThanEqual(coord, ivec3(0))) &&
           all(lessThan(coord, ivec3(VOXEL_GRID_SIZE)));
}


uint sampleVoxel(usampler2D atlas, ivec3 coord) {
    return texelFetch(atlas, voxelCoordToAtlas(coord), 0).r;
}


struct VoxelSample {
    uint category;
    vec3 albedo;
};

VoxelSample readVoxel(usampler2D atlas, ivec3 coord) {
    uvec4 v = texelFetch(atlas, voxelCoordToAtlas(coord), 0);
    VoxelSample s;
    s.category = v.r;
    s.albedo   = vec3(v.gba) / 255.0;
    return s;
}

#endif
