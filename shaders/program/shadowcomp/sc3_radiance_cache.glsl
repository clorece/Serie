// sc3_radiance_cache : world radiance cache update (Phase 3.2)
//
// One thread per probe. Each due probe fires a few rays uniformly over the
// sphere, resolves every hit through the surface cache -- no shading, exactly
// like every other ray in this renderer -- projects the result onto L1 spherical
// harmonics, and blends it into the persistent volume.
//
// This is the far-field half of Lumen's cache pair. The surface cache answers
// "what colour is the thing this ray hit"; this answers "what does the world
// look like from a point in mid-air", which is the question a ray that ran out
// of range is actually asking. See lib/pt/radianceCache.glsl for the layout and
// for why a scalar mean-distance term stands in for DDGI's Chebyshev test.
//
// Cost: RC_PROBE_COUNT / RC_UPDATE_STRIDE probes per frame at RC_RAYS rays each
// -- a few thousand rays, against the hundreds of thousands the screen gather
// casts. It is the cheapest pass in the tracing stack by an order of magnitude.
//
// Runs AFTER sc1_surface_direct so the cache it samples is this frame's.

#define RC_IMAGE
#define SC_IMAGE

// No trailing comments on #include lines: Iris takes the rest of the line as the
// path. What each include is for:
//   pt/surfaceCache    scImageLookup (the image side -- see below)
//   pt/rand            pcgHash, randFloat
//   fragment/sky       sampleSky_fast, for the non-SH path
//   pt/skySH           skySHRadiance
#include "/lib/options.glsl"

#include "/lib/util/common.glsl"
#include "/lib/pt/radianceCache.glsl"
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/pt/skySH.glsl"

// The surface cache is read through its IMAGE binding rather than its sampler,
// even though this pass never writes it. sc1_surface_direct wrote that storage
// earlier in the same frame through the image; reading it back through a sampler
// in a later dispatch would depend on Iris having inserted a texture barrier
// between the two, which is not something to rely on silently. imageLoad against
// the same binding needs only the memory barrier compute passes already get.

// workGroups MUST be literal integers -- Iris parses this out of the source text
// and does not evaluate GLSL, so anything it cannot fold falls back to ONE work
// group. RC_PROBE_COUNT is 32*16*32 = 16384, so 256 groups of 64.
//
// The grid-stride loop below makes coverage independent of the dispatch actually
// launched anyway, for the same reason sc1_surface_direct has one: twice in this
// pack's history the dispatch has silently not been the size the file asked for.
layout(local_size_x = 64) in;
const ivec3 workGroups = ivec3(256, 1, 1);

// Uniform (not cosine) directions: a probe has no normal, so nothing privileges
// one hemisphere. Fibonacci-spiral base rotated by a per-probe random offset --
// the spiral gives near-perfect angular stratification for any ray count, and
// the rotation stops every probe from sampling the same fixed set frame after
// frame, which would bake the spiral's own structure into the volume.
vec3 rcRayDir(int i, int count, float jitter, float phi0) {
    float z   = 1.0 - (2.0 * (float(i) + jitter)) / float(count);
    float r   = sqrt(max(1.0 - z * z, 0.0));
    float phi = phi0 + float(i) * 2.39996323;   // golden angle
    return vec3(r * cos(phi), z, r * sin(phi));
}

void updateProbe(uint idx) {
    ivec3 slot;
    slot.x = int(idx % uint(RC_XZ));
    slot.y = int((idx / uint(RC_XZ)) % uint(RC_Y));
    slot.z = int(idx / uint(RC_XZ * RC_Y));

    // Slot -> the one probe inside the current window that owns it. Walking slot
    // space rather than window space is what keeps this a flat, collision-free
    // enumeration under the toroidal wrap.
    ivec3 org = rcOriginProbe();
    ivec3 pg  = rcSlotToProbe(slot, org);
    vec3  P   = rcProbeWorldPos(pg);

    uint pHash = pcgHash(uint(pg.x * 73856093) ^ uint(pg.y * 19349663)
                       ^ uint(pg.z * 83492791));

    RcSH prev  = rcImageFetch(pg);
    bool valid = prev.meanDist > 0.0;

    // Refresh budget. A probe with no valid history must trace NOW or it reads
    // back as "no coverage" and every consumer silently falls through to its own
    // fallback -- which is how a whole shell of the volume can sit unused behind
    // the camera without anything looking wrong enough to notice.
    if (valid && RC_UPDATE_STRIDE > 1) {
        if (((uint(frameCounter) + pHash) % uint(RC_UPDATE_STRIDE)) != 0u) return;
    }

    uint  seed  = pcgHash(pHash ^ uint(frameCounter) * 2654435761u);
    float jit   = randFloat(seed);
    float phi0  = randFloat(seed) * 6.2831853;
    float eyeAlt = ptEyeAltitude();

    RcSH  cur      = rcSHZero();
    float distSum  = 0.0;

    for (int i = 0; i < RC_RAYS; ++i) {
        vec3 dir = rcRayDir(i, RC_RAYS, jit, phi0);

        // Cone stepping hard from the first metre. These rays exist to describe
        // the far field at 16-block probe spacing, so cascade-0 detail along them
        // is precision this volume cannot store and no consumer can resolve.
        VoxelHit h = traceVoxelCascadedCone(P, dir, float(RC_RAY_DIST), false,
                                            float(RC_CONE_BASE));

        vec3  radiance;
        float hitDist;
        // scHasCoverage, not h.hit: a probe ray can reach past the cache's
        // coverage, and a hit there has no radiance to resolve. Treating it as a
        // miss gives the sky, which is far closer to right than black.
        if (h.hit && scHasCoverage(h.cascade)) {
            radiance = scImageLookupAt(h.pos, h.normal, h.cascade) + h.emission;
            hitDist  = distance(h.pos, P);
        } else {
            // Ray misses are treated as sky whether or not they formally escaped
            // the cascades, and that is a deliberate departure from how the
            // gather handles the same case.
            //
            // The gather must NOT do this: it traces GI_GATHER_DIST (48 blocks),
            // and inside a large cave almost every ray dies at that range without
            // touching anything, so charging them sky floods the cave. These rays
            // run RC_RAY_DIST -- 128 blocks by default -- and a ray that travels
            // that far through Minecraft geometry without hitting a single voxel
            // is outdoors essentially by definition. Distinguishing the two cases
            // here would buy a rounding error and cost the volume its ability to
            // describe open terrain.
            #ifdef GI_SKY_SH
                radiance = skySHRadiance(dir);
            #else
                radiance = sampleSky_fast(dir, eyeAlt);
            #endif
            radiance *= float(GI_SKY_BRIGHTNESS);
            // Emitters the ray passed beside without being stopped by them still
            // glow, exactly as they do for a gather ray.
            radiance += h.emission;
            hitDist   = float(RC_RAY_DIST);
        }

        rcSHAccum(cur, dir, radiance);
        distSum += hitDist;
    }

    // Monte Carlo over the uniform sphere: each sample carries 4*PI / N.
    rcSHScale(cur, (4.0 * PI) / float(RC_RAYS));
    cur.meanDist = distSum / float(RC_RAYS);

    // Firefly clamp at the source, on the constant term, before a spike can be
    // fed back through the surface cache next frame and amplified.
    float lum = dot(cur.l0 * 0.282095, vec3(0.2126, 0.7152, 0.0722));
    if (GI_FIREFLY_MAX < 1000.0 && lum > GI_FIREFLY_MAX) {
        rcSHScale(cur, GI_FIREFLY_MAX / lum);
    }

    // Temporal blend. RC_RAYS is far too few to use raw; the volume is its own
    // accumulator, exactly as the surface cache is. A slot with no valid history
    // takes the new value outright rather than blending toward a probe 512
    // blocks away.
    RcSH outSH = cur;
    if (valid) {
        outSH.l0  = mix(prev.l0,  cur.l0,  RC_BLEND);
        outSH.l1y = mix(prev.l1y, cur.l1y, RC_BLEND);
        outSH.l1z = mix(prev.l1z, cur.l1z, RC_BLEND);
        outSH.l1x = mix(prev.l1x, cur.l1x, RC_BLEND);
        outSH.meanDist = mix(prev.meanDist, cur.meanDist, RC_BLEND);
    }
    // meanDist doubles as the validity flag on the read side, so it must never
    // land on exactly zero -- a probe sealed in stone would otherwise read as
    // "never traced" and be skipped by rcSample rather than correctly rejected.
    outSH.meanDist = max(outSH.meanDist, 1e-3);

    rcImageStore(pg, outSH);
}

void main() {
    // The REAL dispatch, whatever it turned out to be. See the note above the
    // workGroups declaration.
    uint stride = max(gl_NumWorkGroups.x * gl_WorkGroupSize.x, 1u);
    for (uint i = 0u; i < 64u; ++i) {
        uint idx = gl_GlobalInvocationID.x + i * stride;
        if (idx >= uint(RC_PROBE_COUNT)) break;
        updateProbe(idx);
    }
}
