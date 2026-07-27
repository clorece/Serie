#ifndef PT_SURFACE_CACHE_GLSL
#define PT_SURFACE_CACHE_GLSL

// ---------------------------------------------------------------------------
// Lumen surface cache: per-voxel-face outgoing radiance.
//
// This is the piece that decouples lighting from tracing. A ray does not shade
// its hit point; it looks the radiance up here. Lighting cost becomes O(cache
// size) instead of O(rays), which is what makes multi-bounce and reflections
// nearly free once diffuse GI is paid for.
//
// Minecraft makes this unusually cheap. Lumen's hardest problem is fitting
// orthographic "cards" onto arbitrary meshes; on axis-aligned unit cubes that
// problem vanishes outright. The six voxel faces ARE the cards.
//
// Cascade 0 only (one voxel = one block). Beyond it, rays fall back to the world
// radiance cache -- the same near/far split Lumen uses.
//
// ---- Toroidal addressing --------------------------------------------------
//
// The voxel grid is re-rasterised every frame and its origin is
// floor(cameraPosition/vs)*vs, so a given world block lands on a DIFFERENT
// cascade coordinate as soon as the camera moves. Indexing the cache that way
// would invalidate every entry on any motion, which defeats the entire point of
// a persistent cache.
//
// So the cache is indexed by WORLD voxel coordinate wrapped into the volume:
//
//     slot = worldVoxel & (N - 1)
//
// A block keeps its slot no matter where the camera goes. The mapping is a
// bijection over any N-wide window, so within cascade 0 no two visible blocks
// ever collide. What DOES go stale is a slot whose world voxel changed because
// the camera moved the window: the slot still holds radiance belonging to the
// block N away. scTag() below detects exactly that, so a stale slot reads as
// invalid instead of leaking a wrong colour from a block 256 metres off.
//
// N must be a power of two for the mask to work, which is why
// VOXEL_CASCADE_SIZE is restricted to 128 or 256 (the old 192 default is gone).
// ---------------------------------------------------------------------------

#include "/lib/options.glsl"
#include "/lib/pt/voxelCascade.glsl"

#define SC_FACES 6

// Cache footprint matches cascade 0 exactly, with Y expanded x6 for the faces --
// the same "stack along Y" convention the voxel atlas already uses.
#define SC_XZ CASC_XZ
#define SC_Y  CASC_Y

#if VOXEL_CASCADE_SIZE == 256
    #define SC_SHIFT_XZ 8
#elif VOXEL_CASCADE_SIZE == 128
    #define SC_SHIFT_XZ 7
#else
    #error "Surface cache needs a power-of-two VOXEL_CASCADE_SIZE (128 or 256)."
#endif
#define SC_SHIFT_Y 7   // CASC_Y is 128 for every cascade size

#define SC_MASK_XZ (SC_XZ - 1)
#define SC_MASK_Y  (SC_Y  - 1)

const ivec3 SC_IMAGE_DIMS = ivec3(SC_XZ, SC_Y * SC_FACES, SC_XZ);

// ---- Face basis ------------------------------------------------------------
// 0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z

vec3 scFaceNormal(int f) {
    return f == 0 ? vec3( 1.0, 0.0, 0.0)
         : f == 1 ? vec3(-1.0, 0.0, 0.0)
         : f == 2 ? vec3( 0.0, 1.0, 0.0)
         : f == 3 ? vec3( 0.0,-1.0, 0.0)
         : f == 4 ? vec3( 0.0, 0.0, 1.0)
         :          vec3( 0.0, 0.0,-1.0);
}

ivec3 scFaceOffset(int f) {
    return f == 0 ? ivec3( 1, 0, 0)
         : f == 1 ? ivec3(-1, 0, 0)
         : f == 2 ? ivec3( 0, 1, 0)
         : f == 3 ? ivec3( 0,-1, 0)
         : f == 4 ? ivec3( 0, 0, 1)
         :          ivec3( 0, 0,-1);
}

// Dominant axis of a normal -> face index. Used to pick which card a ray hit.
int scFaceFromNormal(vec3 n) {
    vec3 a = abs(n);
    if (a.x >= a.y && a.x >= a.z) return n.x > 0.0 ? 0 : 1;
    if (a.y >= a.z)               return n.y > 0.0 ? 2 : 3;
    return n.z > 0.0 ? 4 : 5;
}

// ---- Addressing ------------------------------------------------------------

// World voxel coordinate of a world-space position (cascade 0 = 1 block/voxel).
ivec3 scWorldVoxel(vec3 worldPos) { return ivec3(floor(worldPos)); }

// Wrap a world voxel into the cache volume. Two's-complement & gives the correct
// non-negative residue for negative coordinates, which plain % does not.
ivec3 scWrap(ivec3 wv) {
    return ivec3(wv.x & SC_MASK_XZ, wv.y & SC_MASK_Y, wv.z & SC_MASK_XZ);
}

ivec3 scImageCoord(ivec3 wv, int f) {
    ivec3 t = scWrap(wv);
    return ivec3(t.x, t.y + f * SC_Y, t.z);
}

// Validity tag: the two bits of each axis immediately above the wrap mask,
// packed into 0..63 -- small enough to survive an fp16 alpha channel exactly.
// Two slots sharing a tag would have to sit 4*N apart (>= 1024 blocks at N=256),
// far outside cascade 0, so within the cache this is collision-free.
float scTag(ivec3 wv) {
    uint tx = uint(wv.x >> SC_SHIFT_XZ) & 3u;
    uint ty = uint(wv.y >> SC_SHIFT_Y ) & 3u;
    uint tz = uint(wv.z >> SC_SHIFT_XZ) & 3u;
    return float(tx | (ty << 2) | (tz << 4));
}

// Inverse of the wrap, for a writer walking slots rather than world positions:
// the unique world voxel inside cascade 0 whose slot is `slot`.
// org is the cascade-0 minimum corner in world voxels.
ivec3 scSlotToWorldVoxel(ivec3 slot, ivec3 org) {
    return ivec3(org.x + ((slot.x - org.x) & SC_MASK_XZ),
                 org.y + ((slot.y - org.y) & SC_MASK_Y ),
                 org.z + ((slot.z - org.z) & SC_MASK_XZ));
}

// Cascade-0 minimum corner, in world voxels.
ivec3 scCascadeOriginVoxel() { return ivec3(floor(cascadeOrigin(0))); }

// ---- Access ----------------------------------------------------------------
// The same storage is reachable two ways, and a translation unit picks ONE:
//
//   SC_READ  -> sampler3D faceRadianceSampler, for consumers that only read
//               (the radiance cache, screen probes, reflections).
//   SC_IMAGE -> image3D  faceRadianceImg,      for the update pass, which both
//               reads and writes.
//
// The update pass deliberately does NOT use the sampler. Reading a texture
// through a sampler while writing the same storage through an image in the same
// dispatch is an aliasing violation; imageLoad against the image binding it
// writes is instead a plain benign race -- each texel reads either the old or
// the new value, which is exactly what a converging feedback cache wants.

// Pull the hit point slightly INTO the block before flooring. A hit sits exactly
// on the face plane, and flooring that lands in the neighbouring (air) voxel
// about half the time, which would read an empty slot.
ivec3 scVoxelForHit(vec3 worldPos, vec3 n) { return scWorldVoxel(worldPos - n * 0.5); }

#ifdef SC_READ
uniform sampler3D faceRadianceSampler;

// Outgoing radiance stored for one voxel face, or 0 when the slot is stale or
// was never lit. Always returns something safe: a miss reads as black, never as
// another block's colour.
vec3 scFetch(ivec3 wv, int f) {
    vec4 c = texelFetch(faceRadianceSampler, scImageCoord(wv, f), 0);
    return (abs(c.a - scTag(wv)) < 0.5) ? c.rgb : vec3(0.0);
}

vec3 scLookup(vec3 worldPos, vec3 n) {
    return scFetch(scVoxelForHit(worldPos, n), scFaceFromNormal(n));
}

// Diagnostics. scLookupRaw ignores the validity tag, so comparing it against
// scLookup separates "the slot was never written" from "the slot holds another
// block's radiance and the tag correctly rejected it".
vec3 scLookupRaw(vec3 worldPos, vec3 n) {
    ivec3 wv = scVoxelForHit(worldPos, n);
    return texelFetch(faceRadianceSampler, scImageCoord(wv, scFaceFromNormal(n)), 0).rgb;
}

bool scTagValid(vec3 worldPos, vec3 n) {
    ivec3 wv = scVoxelForHit(worldPos, n);
    float a = texelFetch(faceRadianceSampler, scImageCoord(wv, scFaceFromNormal(n)), 0).a;
    return abs(a - scTag(wv)) < 0.5;
}
#endif

#ifdef SC_IMAGE
layout(rgba16f) uniform image3D faceRadianceImg;

vec3 scImageFetch(ivec3 wv, int f) {
    vec4 c = imageLoad(faceRadianceImg, scImageCoord(wv, f));
    return (abs(c.a - scTag(wv)) < 0.5) ? c.rgb : vec3(0.0);
}

vec3 scImageLookup(vec3 worldPos, vec3 n) {
    return scImageFetch(scVoxelForHit(worldPos, n), scFaceFromNormal(n));
}

void scImageStore(ivec3 wv, int f, vec3 radiance) {
    imageStore(faceRadianceImg, scImageCoord(wv, f), vec4(radiance, scTag(wv)));
}
#endif

#endif
