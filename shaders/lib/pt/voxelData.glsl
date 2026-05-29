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

// Block categories stored in voxel atlas (.r channel of each RGBA8UI texel)
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u


ivec2 voxelCoordToAtlas(ivec3 c) {
    int col = c.z % VOXEL_ATLAS_COLS;
    int row = c.z / VOXEL_ATLAS_COLS;
    return ivec2(col * VOXEL_GRID_SIZE + c.x, row * VOXEL_GRID_SIZE + c.y);
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
