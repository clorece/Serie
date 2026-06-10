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
//  FUTURE WORK [SUBVOXELIZATION FOR NON-CUBE BLOCKS] (stairs/slabs/fences/etc).
//  Today every solid block is a full cube (category in .r). We could store
//  a per-voxel SHAPE ID (voxelID 25–78) and intersect the real block shape in
//  the voxel via HitShape_Lite() (a tiny SDF/AABB test per shape). To add: carry
//  a shape id per voxel (a spare channel of the RGBA8UI, or widen to a second
//  3D image), and in the DDA hit branch call HitShape(ray, voxelCoord, shapeId,
//  tHit) before accepting the hit. Cube fast-path stays for category==OPAQUE.
//  Brick-skip is unaffected (a brick is "occupied" if it has any non-air voxel).
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
#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u


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
