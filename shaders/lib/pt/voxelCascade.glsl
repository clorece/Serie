#ifndef VOXEL_CASCADE_GLSL
#define VOXEL_CASCADE_GLSL

// ---------------------------------------------------------------------------
// Cascaded voxel grid.
//
// The old grid was a single uniform volume: VOXEL_DISTANCE*32 blocks across at
// one voxel per block. Reaching further meant paying for that resolution
// everywhere, so range was capped by memory (384 blocks cost 75 MB).
//
// Instead, keep several fixed-size grids centred on the camera, each covering
// twice the world of the one before at half the resolution:
//
//   cascade 0   1 block/voxel    192 blocks across
//   cascade 1   2 blocks/voxel   384
//   cascade 2   4 blocks/voxel   768
//   cascade 3   8 blocks/voxel  1536
//
// Every cascade holds the same voxel count, so four of them cost what the single
// 384-block grid used to, while reaching four times further. Detail lands where
// it is resolvable -- sub-block shapes only exist in cascade 0, because a shape
// smaller than a voxel is meaningless once a voxel spans several blocks.
//
// All cascades are stacked along Y inside one 3D image. Iris binds images per
// program and the shadow fragment stage is already close to its image-uniform
// budget, so one stacked atlas beats four separate bindings.
// ---------------------------------------------------------------------------

#include "/lib/options.glsl"
#include "/lib/pt/voxelFormat.glsl"

#define VOXEL_CASCADES 4

// Horizontal/vertical voxel counts per cascade (identical for every cascade).
#define CASC_XZ VOXEL_CASCADE_SIZE
#define CASC_Y  128

const ivec3 CASCADE_DIMS = ivec3(CASC_XZ, CASC_Y, CASC_XZ);
// Stacked atlas: cascade k occupies y in [k*CASC_Y, (k+1)*CASC_Y).
const ivec3 CASCADE_ATLAS_DIMS = ivec3(CASC_XZ, CASC_Y * VOXEL_CASCADES, CASC_XZ);

#define CASC_BRICK 8
#define CASC_SUPER 64
const ivec3 CASCADE_BRICK_DIMS = ivec3(CASC_XZ / CASC_BRICK, CASC_Y / CASC_BRICK, CASC_XZ / CASC_BRICK);
const ivec3 CASCADE_SUPER_DIMS = ivec3(CASC_XZ / CASC_SUPER, CASC_Y / CASC_SUPER, CASC_XZ / CASC_SUPER);

// World size of one voxel in cascade k.
float cascadeVoxelSize(int k) { return float(1 << k); }

// World extent covered by cascade k, per axis.
vec3 cascadeExtent(int k) { return vec3(CASCADE_DIMS) * cascadeVoxelSize(k); }

// Minimum world corner of cascade k.
//
// Snapping the origin to a whole voxel keeps the lattice still as the camera
// moves; without it every coarse voxel would slide continuously and the grid
// would shimmer under any camera motion.
vec3 cascadeOrigin(int k) {
    float vs = cascadeVoxelSize(k);
    return floor(cameraPosition / vs) * vs - cascadeExtent(k) * 0.5;
}

// World position -> voxel coordinate within cascade k (not yet atlas-offset).
bool worldToCascade(vec3 worldPos, int k, out ivec3 coord) {
    vec3 local = (worldPos - cascadeOrigin(k)) / cascadeVoxelSize(k);
    coord = ivec3(floor(local));
    return all(greaterThanEqual(coord, ivec3(0))) && all(lessThan(coord, CASCADE_DIMS));
}

// Fold a per-cascade coordinate into the stacked atlas.
ivec3 cascadeAtlasCoord(ivec3 coord, int k) {
    return ivec3(coord.x, coord.y + k * CASC_Y, coord.z);
}

ivec3 cascadeBrickCoord(ivec3 coord, int k) {
    return ivec3(coord.x >> 3, (coord.y >> 3) + k * (CASC_Y / CASC_BRICK), coord.z >> 3);
}

ivec3 cascadeSuperCoord(ivec3 coord, int k) {
    return ivec3(coord.x >> 6, (coord.y >> 6) + k * (CASC_Y / CASC_SUPER), coord.z >> 6);
}

// Smallest cascade containing a world position, or -1 when it is outside them all.
// A margin keeps rays from picking a cascade they are about to leave immediately.
int cascadeFor(vec3 worldPos, float margin) {
    for (int k = 0; k < VOXEL_CASCADES; ++k) {
        vec3 lo = cascadeOrigin(k) + margin;
        vec3 hi = lo + cascadeExtent(k) - 2.0 * margin;
        if (all(greaterThanEqual(worldPos, lo)) && all(lessThan(worldPos, hi))) return k;
    }
    return -1;
}

int cascadeFor(vec3 worldPos) { return cascadeFor(worldPos, 0.0); }

// Distance at which a ray leaves cascade k, given a world-space origin/direction.
// Returns a negative value when the ray is already outside.
float cascadeExitDistance(vec3 worldPos, vec3 rayDir, int k) {
    vec3 lo = cascadeOrigin(k);
    vec3 hi = lo + cascadeExtent(k);
    vec3 ird = 1.0 / (rayDir + vec3(1e-8));
    vec3 t0 = (lo - worldPos) * ird;
    vec3 t1 = (hi - worldPos) * ird;
    vec3 tf = max(t0, t1);
    return min(tf.x, min(tf.y, tf.z));
}

#endif
