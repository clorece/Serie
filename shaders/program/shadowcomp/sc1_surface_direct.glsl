// sc1_surface_direct : surface cache update (direct light + radiosity)
//
// One thread per cascade-0 voxel; each thread lights all six of its faces and
// writes their outgoing radiance into faceRadianceImg. Runs in shadowcomp, after
// the shadow pass has both rasterised the voxel grid and filled the shadow map,
// so the voxel word and the sun visibility this pass needs are already current.
//
// Cost is fixed and independent of screen resolution -- the whole point of a
// world-space cache. It is amortised further: only 1/SC_UPDATE_STRIDE of the
// volume is touched per frame, selected by a frame-rotating Z phase, so a full
// refresh takes SC_UPDATE_STRIDE frames.
//
// Per face:
//   direct   = sun/moon through the shadow map, plus the block's self-emission
//   indirect = a few cosine rays, each resolving its hit through the cache
//              itself rather than shading it
//   stored   = direct + albedo * indirect, blended into the previous value
//
// The indirect term reading the cache it is writing IS the design: this frame's
// bounce sees last frame's totals, which already contained a bounce, so bounce
// count grows by one per refresh and multi-bounce costs nothing extra. It also
// means the cache converges over several frames rather than being exact on any
// single one -- hence the temporal blend, which is what keeps a 2-ray estimate
// from visibly boiling.
//
// The plan called for splitting this across two dispatches (direct in
// shadowcomp1, radiosity in shadowcomp2). Merged deliberately: with only
// 1/STRIDE of the volume refreshed per frame, a separate radiosity pass would
// still be sampling mostly-previous-frame direct light, so the split bought a
// second full dispatch and a read-after-write hazard between passes for no
// accuracy gain.

// This pass reads AND writes the cache; see surfaceCache.glsl.
#define SC_IMAGE

// NOTE: no trailing comments on #include lines anywhere in this pack. Iris takes
// the entire rest of the line as the path, so "#include "/x.glsl" // why" fails
// to resolve at pack load. What each include is for:
//   util/common      isInShadow
//   pt/sampling      buildTBN, cosHemisphereDir
//   fragment/sky     sampleSky_fast
//   blocklightColors GetSpecialBlocklightColor
#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/blocklightColors.glsl"

// GRID-STRIDE dispatch, deliberately.
//
// Coverage here does NOT depend on the dispatch being the size this file asks
// for, because twice now it has not been. A 3D dispatch of
// ivec3(SC_XZ/8, SC_Y/8, SC_XZ/SC_UPDATE_STRIDE) over an 8x8x1 group produced a
// long thin bar instead of a volume, and replacing it with a flat 1D dispatch of
// 4096 groups x 256 still left most of the cache unwritten (GI_DEBUG_VIEW 5 came
// back red -- tag rejected -- across the whole cascade).
//
// So the number of threads that actually launch is treated as a performance
// detail, not a correctness input. gl_NumWorkGroups and gl_WorkGroupSize report
// the REAL dispatch, so striding by their product covers the volume exactly once
// whatever that dispatch turns out to be: one iteration per thread if the full
// request was honoured, more if it was not.
// workGroups MUST be literal integers.
//
// Iris reads this declaration out of the source text rather than evaluating
// GLSL, so an expression it cannot fold -- as
// ivec3((SC_XZ * SC_Y * SC_XZ / SC_UPDATE_STRIDE) / 256, 1, 1) was -- silently
// falls back to a single work group. That is the whole story behind the strip:
// one group of 256 threads ran, so with the grid-stride cap the pass reached
// 256 * SC_MAX_ITERS voxels, i.e. one Z slab, and GI_DEBUG_VIEW 5 showed a green
// band on red. Both compute passes that already worked in this pack
// (s0_shape_table, sc0_entity_bvh) use plain literals here; this one did not.
//
// 4096 x 256 = 1,048,576 threads. The grid-stride loop below turns that into
// full coverage for any cascade size or update stride: 8 iterations per thread
// at SC_XZ 256 with SC_UPDATE_STRIDE 1, one iteration at stride 8.
layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(4096, 1, 1);

// Voxel word at a cascade-0 LOCAL coordinate, or air outside the volume.
uint fetchLocal(ivec3 local) {
    if (any(lessThan(local, ivec3(0))) || any(greaterThanEqual(local, CASCADE_DIMS))) {
        return 0u; // outside cascade 0 -> treat as air, so border faces stay lit
    }
    return texelFetch(voxelSampler, cascadeAtlasCoord(local, 0), 0).r;
}

void updateVoxel(uint idx) {
    // --- flat index -> slot -> world voxel ----------------------------------
    // idx enumerates one Z slab set: SC_XZ * SC_Y voxels per slab, and
    // SC_XZ / SC_UPDATE_STRIDE slabs.
    int slabArea = SC_XZ * SC_Y;
    int zIdx = int(idx) / slabArea;
    int rem  = int(idx) % slabArea;

    ivec3 slot;
    slot.x = rem % SC_XZ;
    slot.y = rem / SC_XZ;
    // Frame-rotating Z phase: each frame covers every SC_UPDATE_STRIDE'th slab.
    slot.z = zIdx * SC_UPDATE_STRIDE + (frameCounter % SC_UPDATE_STRIDE);

    if (any(greaterThanEqual(slot, ivec3(SC_XZ, SC_Y, SC_XZ)))) return;

    ivec3 org   = scCascadeOriginVoxel();
    ivec3 wv    = scSlotToWorldVoxel(slot, org);
    ivec3 local = wv - org;

    uint w = fetchLocal(local);

    // Air voxels are still written. Leaving them alone would let a slot keep the
    // radiance of whatever solid block used to occupy it, and the tag would
    // agree -- the tag detects a change of WORLD VOXEL, not a change of contents
    // at the same voxel (a block being broken, say).
    if (voxelIsAir(w)) {
        for (int f = 0; f < SC_FACES; ++f) scImageStore(wv, f, vec3(0.0));
        return;
    }

    uint cat    = voxelCategory(w);
    vec3 albedo = voxelAlbedo(w);

    // Self-emission is a property of the block, not of any one face.
    vec3 emission = vec3(0.0);
    if (cat == VOXEL_LIGHT) {
        emission = GetSpecialBlocklightColor(int(voxelLightMat(w))).rgb * float(GI_EMISSION);
    } else if (cat == VOXEL_EMISSIVE) {
        emission = albedo * float(GI_EMISSION) * SC_EMISSIVE_BOOST;
    }

    vec3  lightVec  = ptWorldLightVector();
    vec3  lightCol  = ptLightColor();
    float rain      = 1.0 - rainStrength * 0.75;
    float eyeAlt    = ptEyeAltitude();
    uint  seed      = pcgHash(uint(wv.x * 73856093) ^ uint(wv.y * 19349663)
                            ^ uint(wv.z * 83492791) ^ uint(frameCounter) * 2654435761u);

    for (int f = 0; f < SC_FACES; ++f) {
        vec3 n = scFaceNormal(f);

        // A face buried against a solid neighbour emits nothing: no ray can see
        // it, and lighting it would leak through a one-block partition whenever
        // a lookup landed on the wrong side.
        if (!voxelIsAir(fetchLocal(local + scFaceOffset(f)))) {
            scImageStore(wv, f, vec3(0.0));
            continue;
        }

        // Face centre, lifted off the plane so neither the shadow lookup nor the
        // bounce rays start inside the block they belong to.
        vec3 faceCentre = vec3(wv) + 0.5 + n * 0.5;
        vec3 origin     = faceCentre + n * 0.02;

        // --- direct ---------------------------------------------------------
        vec3  direct = emission;
        float NdotL  = dot(n, lightVec);
        if (NdotL > 0.0) {
            // isInShadow wants a CAMERA-RELATIVE position: it applies
            // shadowModelView, which is already camera-centred.
            if (!isInShadow(origin + n * 0.03 - cameraPosition)) {
                direct += albedo * lightCol * NdotL * rain;
            }
        }

        // --- sky visibility ---------------------------------------------------
        // There is no lightmap in a world-space pass, so this face has to work
        // out its own sky access: one occlusion probe angled toward the sky but
        // kept inside the face's hemisphere. A downward-facing (ceiling) face
        // ends up probing along its own normal and is correctly found blind to
        // the sky.
        //
        // Without this the cache itself leaks: a cave wall's bounce rays nearly
        // all die on SC_BOUNCE_DIST in open air, and charging them full sky bakes
        // daylight into cave geometry, which the gather then faithfully reads
        // back out. Fixing only the gather would not have removed the leak.
        vec3 skyDir = normalize(n + vec3(0.0, 1.5, 0.0));
        if (dot(skyDir, n) < 0.1) skyDir = n;
        float faceSkyVis = traceVoxelOccluded(origin, skyDir, float(SC_SKY_PROBE_DIST), true)
                         ? 0.0 : 1.0;

        // --- indirect -------------------------------------------------------
        // Cosine-weighted, so the estimator is a plain mean: no 1/pdf, no NdotL.
        vec3 incoming = vec3(0.0);
        for (int r = 0; r < SC_BOUNCE_RAYS; ++r) {
            vec3 dir = cosHemisphereDir(n, randFloat(seed), randFloat(seed));
            VoxelHit h = traceVoxelCascaded(origin, dir, float(SC_BOUNCE_DIST), true);

            if (h.hit) {
                // The whole point: resolve the hit through the cache instead of
                // shading it. Emitters passed through on the way are additive.
                incoming += scImageLookup(h.pos, h.normal) + h.emission;
            } else {
                // A ray that left the cascades outright sees sky unconditionally.
                // One that merely ran out of SC_BOUNCE_DIST is still inside the
                // grid and knows nothing about the far field, so it only gets sky
                // in proportion to this face's measured sky access.
                //
                // Never sampleSky(): it carries the sun and moon discs (x1000 and
                // x100) and a single ray clipping one is a guaranteed firefly.
                //
                // This reads the atmosphere LUT in colortex12, which prepare.fsh
                // rebuilds LATER in the frame than shadowcomp runs -- so the sky
                // colour here is one frame stale. Harmless: the LUT changes over
                // minutes of world time, and the cache's own temporal blend has a
                // far longer time constant than a frame.
                float skyWeight = h.escaped ? 1.0 : faceSkyVis;
                incoming += sampleSky_fast(dir, eyeAlt) * float(GI_SKY_BRIGHTNESS) * skyWeight
                          + h.emission;
            }
        }
        incoming *= 1.0 / float(SC_BOUNCE_RAYS);

        vec3 total = direct + albedo * incoming;

        // Firefly clamp at the source, before the value can be fed back into the
        // next frame's bounce and amplified.
        float lum = dot(total, vec3(0.2126, 0.7152, 0.0722));
        if (GI_FIREFLY_MAX < 1000.0 && lum > GI_FIREFLY_MAX) {
            total *= GI_FIREFLY_MAX / lum;
        }

        // --- temporal blend -------------------------------------------------
        // A few rays per face per refresh is far too noisy to use raw. Blending
        // against the slot's previous value turns the cache into its own
        // accumulator. A slot whose tag has gone stale has no usable history, so
        // it takes the new value outright rather than blending toward a
        // different block's radiance.
        vec4  prev  = imageLoad(faceRadianceImg, scImageCoord(wv, f));
        bool  valid = abs(prev.a - scTag(wv)) < 0.5;
        vec3  outR  = valid ? mix(prev.rgb, total, SC_BLEND) : total;

        scImageStore(wv, f, outR);
    }
}

void main() {
    uint total  = uint(SC_XZ * SC_Y * SC_XZ / SC_UPDATE_STRIDE);
    // The REAL dispatch, whatever it turned out to be -- not what workGroups
    // asked for. Guarded against a degenerate report so this can never spin.
    uint stride = max(gl_NumWorkGroups.x * gl_WorkGroupSize.x, 1u);

    // Hard iteration cap. If the dispatch is honoured this is one pass and the
    // cap never binds. If it is far smaller than requested, this bounds the work
    // per thread instead of letting a single invocation walk millions of voxels
    // and hang the GPU -- coverage then comes up short, which GI_DEBUG_VIEW 5
    // will show, rather than taking the driver down.
    for (uint i = 0u; i < uint(SC_MAX_ITERS); ++i) {
        uint idx = gl_GlobalInvocationID.x + i * stride;
        if (idx >= total) break;
        updateVoxel(idx);
    }
}
