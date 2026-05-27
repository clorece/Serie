#ifndef VOXEL_DATA_GLSL
#define VOXEL_DATA_GLSL

// Voxel grid: 128^3, centered on floor(cameraPosition)
// Provides +-64 block radius around the player in each axis
#define VOXEL_GRID_SIZE  128
#define VOXEL_RADIUS     64

// Block categories stored in voxel atlas (.r channel of each RGBA8UI texel)
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u

// Atlas layout: 2048 x 1024 RGBA8UI
// 16 columns x 8 rows, each cell = one 128x128 Z-slice of the grid
#define VOXEL_ATLAS_COLS 16
#define VOXEL_ATLAS_ROWS 8

// Convert a voxel grid coordinate [0, VOXEL_GRID_SIZE) to a 2D atlas texel
ivec2 voxelCoordToAtlas(ivec3 c) {
    int col = c.z % VOXEL_ATLAS_COLS;
    int row = c.z / VOXEL_ATLAS_COLS;
    return ivec2(col * VOXEL_GRID_SIZE + c.x, row * VOXEL_GRID_SIZE + c.y);
}

// Convert absolute world position to an integer voxel grid coordinate.
// gridOrigin = floor(cameraPosition) - VOXEL_RADIUS
// Returns true and writes coord when inside the grid, false otherwise.
bool worldToVoxel(vec3 worldPos, vec3 gridOrigin, out ivec3 coord) {
    vec3 local = worldPos - gridOrigin;
    coord = ivec3(floor(local));
    return all(greaterThanEqual(coord, ivec3(0))) &&
           all(lessThan(coord, ivec3(VOXEL_GRID_SIZE)));
}

// Sample voxel type at an integer coordinate using a usampler2D (deferred read path).
uint sampleVoxel(usampler2D atlas, ivec3 coord) {
    return texelFetch(atlas, voxelCoordToAtlas(coord), 0).r;
}

// Full voxel contents: block category + stored albedo color.
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
