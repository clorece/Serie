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
// ---- Cascades (Phase 3.2) --------------------------------------------------
//
// The cache used to cover cascade 0 only. Everything past 128 blocks resolved
// its hit against a slot addressed for a DIFFERENT world voxel, the tag
// correctly rejected it, and the ray got black -- so distant geometry was not
// merely approximate, it was unlit.
//
// It now covers SC_CASCADES of the voxel clipmap, each at that cascade's own
// resolution (1 block/voxel, then 2, ...). This is old Lumen's structure
// exactly: a cascaded voxel clipmap holding radiance in six directions, which
// is also what makes cone-stepping possible in voxelTrace.glsl -- a ray may
// only be promoted to a coarser cascade if there is radiance stored there to
// resolve against.
//
// Cascade k occupies y in [k*SC_FACES*SC_Y, (k+1)*SC_FACES*SC_Y) of the same
// stacked image, matching the "stack along Y" convention the voxel atlas uses.
//
// SC_CASCADES is capped at 2 in options.glsl, and the reason is a hard limit
// rather than a taste one: the image is SC_Y * SC_FACES * SC_CASCADES tall, so
// three cascades at SC_XZ 256 would need 2304 texels of height and
// GL_MAX_3D_TEXTURE_SIZE is 2048 on a good deal of hardware.
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
// where worldVoxel is measured in cascade-k voxels (floor(worldPos / 2^k)). A
// block keeps its slot no matter where the camera goes. The mapping is a
// bijection over any N-wide window, so within one cascade no two visible blocks
// ever collide. What DOES go stale is a slot whose world voxel changed because
// the camera moved the window: the slot still holds radiance belonging to the
// voxel N away. scTag() below detects exactly that, so a stale slot reads as
// invalid instead of leaking a wrong colour from a block 256 metres off.
//
// N must be a power of two for the mask to work, which is why
// VOXEL_CASCADE_SIZE is restricted to 128 or 256 (the old 192 default is gone).
// ---------------------------------------------------------------------------

#include "/lib/options.glsl"
#include "/lib/pt/voxelCascade.glsl"

#define SC_FACES 6

#ifndef SC_CASCADES
    #define SC_CASCADES 1
#endif
#if SC_CASCADES > VOXEL_CASCADES
    #error "SC_CASCADES cannot exceed VOXEL_CASCADES."
#endif

// Cache footprint matches the voxel cascades exactly, with Y expanded x6 for the
// faces and then again by the cascade count.
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

// Voxels in one cascade's slice of the cache -- the writer's dispatch unit.
#define SC_VOXELS_PER_CASCADE (SC_XZ * SC_Y * SC_XZ)

const ivec3 SC_IMAGE_DIMS = ivec3(SC_XZ, SC_Y * SC_FACES * SC_CASCADES, SC_XZ);

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

// ---- Cascade selection -----------------------------------------------------

// The FINEST cached cascade whose window contains this position, or -1 when it
// is outside every one of them (nothing useful is stored, and the caller must
// fall back -- the far-field radiance cache, or the sky).
//
// Used ONLY where no VoxelHit is available (the debug views, and consumers
// shading a rasterised surface). Anything holding a trace result must use
// VoxelHit.cascade instead -- see scLookupAt for why the two differ and why
// picking the wrong one reads black.
int scCoverageCascade(vec3 worldPos) {
    for (int k = 0; k < SC_CASCADES; ++k) {
        vec3 lo = cascadeOrigin(k);
        vec3 hi = lo + cascadeExtent(k);
        if (all(greaterThanEqual(worldPos, lo)) && all(lessThan(worldPos, hi))) return k;
    }
    return -1;
}

// ---- Why every cascade is maintained EVERYWHERE, including near the camera --
//
// It is tempting for the update pass to skip a coarse voxel that sits well
// inside a finer cascade, on the grounds that a reader would have picked the
// finer one anyway. At SC_CASCADES 2 that would skip everything within 128
// metres and halve the pass.
//
// It is wrong, and the reason is cone stepping. A promoted ray resolves its hit
// in cascade 1 after only GI_CONE_BASE metres of travel -- 16 by default, deep
// inside cascade 0's window -- and it must read cascade 1 there, because its hit
// point lies on a 2-block voxel face whose cascade-0 neighbour is usually air.
// Skipping those slots makes every cone-stepped ray in the near field read black.
//
// The cost is far below the naive doubling anyway: a coarse cascade holds the
// same voxel COUNT over eight times the volume, so its near field is an eighth
// the work of cascade 0's, and everything outside SC_NEAR_DIST still has to earn
// its refresh through the feedback gate.

// ---- Addressing ------------------------------------------------------------

// World voxel coordinate at cascade k's resolution.
ivec3 scWorldVoxel(vec3 worldPos, int k) {
    return ivec3(floor(worldPos / cascadeVoxelSize(k)));
}

// Wrap a world voxel into the cache volume. Two's-complement & gives the correct
// non-negative residue for negative coordinates, which plain % does not.
ivec3 scWrap(ivec3 wv) {
    return ivec3(wv.x & SC_MASK_XZ, wv.y & SC_MASK_Y, wv.z & SC_MASK_XZ);
}

ivec3 scImageCoord(ivec3 wv, int f, int k) {
    ivec3 t = scWrap(wv);
    return ivec3(t.x, t.y + (k * SC_FACES + f) * SC_Y, t.z);
}

// Validity tag: the two bits of each axis immediately above the wrap mask,
// packed into 0..63 -- small enough to survive an fp16 alpha channel exactly.
// Two slots sharing a tag would have to sit 4*N voxels apart (>= 1024 blocks at
// N=256 in cascade 0, and proportionally further in coarser ones), far outside
// the cascade, so within one cascade this is collision-free. Cascades cannot
// alias each other at all: they occupy disjoint slices of the image.
float scTag(ivec3 wv) {
    uint tx = uint(wv.x >> SC_SHIFT_XZ) & 3u;
    uint ty = uint(wv.y >> SC_SHIFT_Y ) & 3u;
    uint tz = uint(wv.z >> SC_SHIFT_XZ) & 3u;
    return float(tx | (ty << 2) | (tz << 4));
}

// Inverse of the wrap, for a writer walking slots rather than world positions:
// the unique world voxel inside cascade k whose slot is `slot`.
// org is that cascade's minimum corner in ITS OWN voxel units.
ivec3 scSlotToWorldVoxel(ivec3 slot, ivec3 org) {
    return ivec3(org.x + ((slot.x - org.x) & SC_MASK_XZ),
                 org.y + ((slot.y - org.y) & SC_MASK_Y ),
                 org.z + ((slot.z - org.z) & SC_MASK_XZ));
}

// Cascade k's minimum corner, in cascade-k voxels.
ivec3 scCascadeOriginVoxel(int k) {
    return ivec3(floor(cascadeOrigin(k) / cascadeVoxelSize(k)));
}

// Does a VoxelHit.cascade land inside the cache at all?
//
// k < 0 means nothing in the voxel grid resolved it -- an entity box, or a ray
// whose origin was outside every cascade. k >= SC_CASCADES means the ray walked
// past the cache's coverage the ordinary way, by physically leaving cascade
// SC_CASCADES-1's box. Neither has cached radiance, and both should be routed to
// the far field rather than contributing black.
bool scHasCoverage(int k) { return k >= 0 && k < SC_CASCADES; }

// Pull the hit point slightly INTO the voxel before flooring. A hit sits exactly
// on the face plane, and flooring that lands in the neighbouring (air) voxel
// about half the time, which would read an empty slot. Half a voxel of THIS
// cascade, so the nudge scales with the cell it is addressing.
ivec3 scVoxelForHit(vec3 worldPos, vec3 n, int k) {
    float vs = cascadeVoxelSize(k);
    return ivec3(floor((worldPos - n * (0.5 * vs)) / vs));
}

// ---- Access ----------------------------------------------------------------
// The same storage is reachable two ways, and a translation unit picks ONE:
//
//   SC_READ  -> sampler3D faceRadianceSampler, for consumers that only read
//               (the radiance cache, the gather, reflections).
//   SC_IMAGE -> image3D  faceRadianceImg,      for the update pass, which both
//               reads and writes.
//
// The update pass deliberately does NOT use the sampler. Reading a texture
// through a sampler while writing the same storage through an image in the same
// dispatch is an aliasing violation; imageLoad against the image binding it
// writes is instead a plain benign race -- each texel reads either the old or
// the new value, which is exactly what a converging feedback cache wants.

// ---- Update feedback -------------------------------------------------------
//
// Lumen does not refresh its whole surface cache. Rays record which card pages
// they actually hit into a feedback buffer, and only those pages get updated
// (LumenSurfaceCacheFeedback). This is that idea at brick granularity: every
// cache lookup stamps the current frame onto the 8^3 brick it read, and the
// update pass refuses to spend work on a brick nothing has looked at recently.
//
// The volume is tiny -- one byte per brick, 32 x 16 x 32 per cascade, so 16 KB
// times SC_CASCADES -- so it lives in L2 and both the stamp and the test are
// effectively free. It is addressed toroidally like the cache itself; the wrap
// and the >>3 commute for power-of-two masks, so a brick's slot here always
// matches the bricks its voxels occupy in faceRadianceImg.
//
// WHY THE PROPAGATION IS BOUNDED. The gather's rays stamp what the camera can
// see. If the update pass's own bounce rays also stamped, the requested set
// would grow by SC_BOUNCE_DIST every frame -- requested bricks cast rays, those
// hits get requested, and next frame THEY cast rays -- saturating the whole
// cascade within about eight frames and making the whole scheme worthless. So
// bounce-ray stamping is restricted to the near field, which always refreshes
// anyway: that warms exactly one shell around the camera and then stops, because
// the shell's own voxels are outside the near field and do not stamp.
#ifdef SC_FEEDBACK
layout(r8ui) uniform uimage3D scRequestImg;

ivec3 scRequestCoord(ivec3 wv, int k) {
    return ivec3((wv.x >> 3) & ((SC_XZ >> 3) - 1),
                 ((wv.y >> 3) & ((SC_Y  >> 3) - 1)) + k * (SC_Y >> 3),
                 (wv.z >> 3) & ((SC_XZ >> 3) - 1));
}

// Iris wraps frameCounter at 720720, which is not a multiple of 256, so the
// stamp's phase jumps once every ~3.3 hours at 60 fps. The worst case is that
// some bricks read as stale for a frame and skip one refresh; the gather
// re-stamps them immediately, so it self-heals on the next frame.
uint scFrameStamp() { return uint(frameCounter) & 255u; }

void scRequestAt(ivec3 wv, int k) {
    ivec3 c = scRequestCoord(wv, k);
    // Load-compare-store, not a blind store. A million gather rays land in a few
    // hundred bricks, so almost every one of these would be re-stamping a value
    // the brick already carries this frame. The load hits L2; the store almost
    // never happens.
    if (imageLoad(scRequestImg, c).r != scFrameStamp()) {
        imageStore(scRequestImg, c, uvec4(scFrameStamp(), 0u, 0u, 0u));
    }
}

// Has anything looked at this brick recently enough to be worth refreshing?
// SC_REQUEST_TTL must be >= the largest refresh period, or a brick could be
// stamped, have its scheduled turn fall outside the window, and never update.
bool scRequested(ivec3 wv, int k) {
    uint stamp = imageLoad(scRequestImg, scRequestCoord(wv, k)).r;
    return ((scFrameStamp() - stamp) & 255u) < uint(SC_REQUEST_TTL);
}
#endif

#ifdef SC_READ
uniform sampler3D faceRadianceSampler;

// Outgoing radiance stored for one voxel face, or 0 when the slot is stale or
// was never lit. Always returns something safe: a miss reads as black, never as
// another block's colour.
vec3 scFetch(ivec3 wv, int f, int k) {
    vec4 c = texelFetch(faceRadianceSampler, scImageCoord(wv, f, k), 0);
    return (abs(c.a - scTag(wv)) < 0.5) ? c.rgb : vec3(0.0);
}

// Look a hit up at the cascade that RESOLVED it -- VoxelHit.cascade, not
// whichever cascade happens to contain the point.
//
// Those differ whenever cone stepping promoted the ray, and using the wrong one
// reads black. A hit found in cascade 1 lies on a 2-block voxel face; the
// cascade-0 voxel just inside that face is often air, because a coarse voxel
// counts as occupied if any block within it is. Asking cascade 0 lands on a slot
// the update pass never wrote and the tag correctly rejects it.
//
vec3 scLookupAt(vec3 worldPos, vec3 n, int k) {
    if (!scHasCoverage(k)) return vec3(0.0);
    ivec3 wv = scVoxelForHit(worldPos, n, k);
    // Only ray-casting consumers opt into stamping (SC_FEEDBACK_WRITE). The debug
    // views in d7_composite call this too and must NOT stamp: they would keep
    // bricks warm that nothing real is looking at, which is exactly the
    // measurement the feedback volume exists to make.
    #ifdef SC_FEEDBACK_WRITE
    scRequestAt(wv, k);
    #endif
    return scFetch(wv, scFaceFromNormal(n), k);
}

// Cascade-inferring form, for callers that have a position but no trace result
// (the debug views). Prefer scLookupAt wherever a VoxelHit is in hand.
vec3 scLookup(vec3 worldPos, vec3 n) {
    return scLookupAt(worldPos, n, scCoverageCascade(worldPos));
}

// Diagnostics. scLookupRaw ignores the validity tag, so comparing it against
// scLookup separates "the slot was never written" from "the slot holds another
// block's radiance and the tag correctly rejected it".
vec3 scLookupRaw(vec3 worldPos, vec3 n) {
    int k = scCoverageCascade(worldPos);
    if (k < 0) return vec3(0.0);
    ivec3 wv = scVoxelForHit(worldPos, n, k);
    return texelFetch(faceRadianceSampler, scImageCoord(wv, scFaceFromNormal(n), k), 0).rgb;
}

bool scTagValid(vec3 worldPos, vec3 n) {
    int k = scCoverageCascade(worldPos);
    if (k < 0) return false;
    ivec3 wv = scVoxelForHit(worldPos, n, k);
    float a = texelFetch(faceRadianceSampler, scImageCoord(wv, scFaceFromNormal(n), k), 0).a;
    return abs(a - scTag(wv)) < 0.5;
}

// The tag actually STORED in the slot, and the tag the reader EXPECTS there.
// Displaying both settles what a red coverage map means: a stored tag of 0 with
// a non-zero expected tag says the slot was never written, whereas two differing
// non-zero values would say writer and reader disagree about addressing.
float scStoredTag(vec3 worldPos, vec3 n) {
    int k = scCoverageCascade(worldPos);
    if (k < 0) return 0.0;
    ivec3 wv = scVoxelForHit(worldPos, n, k);
    return texelFetch(faceRadianceSampler, scImageCoord(wv, scFaceFromNormal(n), k), 0).a;
}

float scExpectedTag(vec3 worldPos, vec3 n) {
    int k = scCoverageCascade(worldPos);
    if (k < 0) return 0.0;
    return scTag(scVoxelForHit(worldPos, n, k));
}
#endif

#ifdef SC_IMAGE
layout(rgba16f) uniform image3D faceRadianceImg;

vec3 scImageFetch(ivec3 wv, int f, int k) {
    vec4 c = imageLoad(faceRadianceImg, scImageCoord(wv, f, k));
    return (abs(c.a - scTag(wv)) < 0.5) ? c.rgb : vec3(0.0);
}

// See scLookupAt: the cascade must be the one that RESOLVED the hit.
vec3 scImageLookupAt(vec3 worldPos, vec3 n, int k) {
    if (k < 0 || k >= SC_CASCADES) return vec3(0.0);
    return scImageFetch(scVoxelForHit(worldPos, n, k), scFaceFromNormal(n), k);
}

vec3 scImageLookup(vec3 worldPos, vec3 n) {
    return scImageLookupAt(worldPos, n, scCoverageCascade(worldPos));
}

void scImageStore(ivec3 wv, int f, int k, vec3 radiance) {
    imageStore(faceRadianceImg, scImageCoord(wv, f, k), vec4(radiance, scTag(wv)));
}
#endif

#endif
