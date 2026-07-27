// sc1_surface_direct : surface cache update (direct light + radiosity)
//
// One thread per cascade-0 voxel; each thread lights all six of its faces and
// writes their outgoing radiance into faceRadianceImg. Runs in shadowcomp, after
// the shadow pass has both rasterised the voxel grid and filled the shadow map,
// so the voxel word and the sun visibility this pass needs are already current.
//
// Cost is fixed and independent of screen resolution -- the whole point of a
// world-space cache. Four gates keep that fixed cost small, applied in
// increasing order of expense so the cheapest test rejects the most work:
//
//   1. refresh budget    pure ALU; period scales with distance to the camera
//   2. super-brick/brick two L1-resident fetches; rejects all empty space
//   3. air voxel         one atlas fetch
//   4. face round-robin  SC_FACE_STRIDE faces of six per frame
//
// Per face:
//   direct   = sun/moon through the shadow map, plus the block's self-emission
//   indirect = a few cosine rays, each resolving its hit through the cache
//              itself rather than shading it
//   stored   = direct + albedo * indirect, blended into the previous value
//
// Sky access is NOT traced. It is read out of the voxel word, where the
// voxeliser banked Minecraft's own skylight lightmap -- see voxelFormat.glsl.
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
//   pt/emitterPalette  emitterColor (via voxelTrace)
#include "/lib/options.glsl"

// Feedback: this pass READS the request volume as its main gate, and stamps it
// from near-field bounce rays only. It deliberately does NOT set
// SC_FEEDBACK_WRITE -- that would make every cache lookup stamp, including the
// far-field ones, which is exactly the unbounded-growth failure described in
// surfaceCache.glsl. This has to sit AFTER options.glsl and BEFORE
// surfaceCache.glsl: the first defines SURFACE_CACHE_FEEDBACK, the second reads
// SC_FEEDBACK.
#ifdef SURFACE_CACHE_FEEDBACK
    #define SC_FEEDBACK
#endif

#include "/lib/util/common.glsl"
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"

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
// full coverage for any cascade size: 8 iterations per thread at SC_XZ 256, two
// at SC_XZ 128. The loop no longer divides by SC_UPDATE_STRIDE -- every voxel is
// visited every frame and decides for itself whether it is due, which is what
// lets the refresh rate vary with distance.
//
// The 256-wide group is also half an 8^3 brick under the brick-major index in
// updateVoxel, so the occupancy test there is group-uniform.
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
    // --- flat index -> cascade-0 local coordinate ---------------------------
    // BRICK-MAJOR ordering, deliberately: consecutive threads walk one 8^3 brick
    // to completion before moving to the next, so a 256-thread work group lands
    // entirely inside a single brick and the occupancy test below is uniform
    // across the group. One fetch then decides the fate of all 256 threads
    // instead of each of them diverging on its own.
    //
    // Enumerating LOCAL space rather than slot space is what makes that work.
    // The two differ by the toroidal wrap, and the cascade origin is not
    // 8-aligned, so an 8-aligned run of slots straddles two bricks in the
    // occupancy image and the group-uniform test would be a lie. Local space is
    // also a bijection onto the slots -- the wrap is one-to-one over any N-wide
    // window and the cascade is exactly N wide -- so every slot is still visited
    // exactly once.
    const ivec3 bDims = ivec3(SC_XZ >> 3, SC_Y >> 3, SC_XZ >> 3);

    int brickIdx = int(idx >> 9);   // 512 voxels per 8^3 brick
    int inBrick  = int(idx & 511u);

    ivec3 b;
    b.x =  brickIdx % bDims.x;
    b.y = (brickIdx / bDims.x) % bDims.y;
    b.z =  brickIdx / (bDims.x * bDims.y);

    ivec3 local = b * 8 + ivec3(inBrick & 7, (inBrick >> 3) & 7, (inBrick >> 6) & 7);

    ivec3 org = scCascadeOriginVoxel();
    ivec3 wv  = org + local;

    // --- gate 1: distance band (pure ALU, no memory touched) ----------------
    //
    // Lumen budgets card captures per frame and spends that budget by priority
    // rather than refreshing the whole scene on a fixed rotation. The period
    // comes from distance, so the wall you are standing against relights the
    // frame the sun moves while the far corner of the cascade -- a handful of
    // pixels, seen through the temporal filter anyway -- takes
    // SC_UPDATE_STRIDE frames.
    vec3  dcam      = vec3(wv) + 0.5 - cameraPosition;
    float dist2     = dot(dcam, dcam);
    bool  nearField = dist2 < float(SC_NEAR_DIST * SC_NEAR_DIST);

    int period = nearField ? 1
               : dist2 < float(SC_MID_DIST * SC_MID_DIST) ? max(SC_UPDATE_STRIDE / 4, 1)
               : dist2 < float(SC_FAR_DIST * SC_FAR_DIST) ? max(SC_UPDATE_STRIDE / 2, 1)
               : SC_UPDATE_STRIDE;

    // --- gate 2: has anything actually looked at this brick? ----------------
    //
    // The strongest filter, and group-uniform: a whole work group shares one
    // brick, so one L2 fetch decides all 256 threads. Everything outside the
    // always-warm near field must earn its refresh by having been hit by a
    // gather ray within SC_REQUEST_TTL frames. Bricks nothing looks at hold
    // their last value; nothing reads them, so nothing notices.
    #ifdef SC_FEEDBACK
    if (!nearField && !scRequested(wv)) return;
    #endif

    // --- gate 3: refresh phase ----------------------------------------------
    if (period > 1) {
        uint phase = pcgHash(uint(wv.x * 73856093) ^ uint(wv.y * 19349663)
                           ^ uint(wv.z * 83492791));
        // Every period the ladder can produce is a power of two, so the mask is
        // exact and this stays a single AND. Hashing the phase spreads updates
        // as dither instead of the planar sweep a slab stride produced.
        if (((uint(frameCounter) + phase) & uint(period - 1)) != 0u) return;
    }

    // --- gate 4: hierarchical occupancy (group-uniform, L1-resident) --------
    // The 64^3 super-brick and 8^3 brick maps the DDA already builds answer
    // "is there any geometry near here" in two fetches over 32 and 16 KB of
    // data, both of which stay in cache. Roughly nine tenths of this volume is
    // open air, and before these tests every one of those threads paid a fetch
    // into the 134 MB voxel atlas to learn it.
    if (texelFetch(superBrickSampler, cascadeSuperCoord(local, 0), 0).r == 0u) return;
    if (texelFetch(brickSampler,      cascadeBrickCoord(local, 0), 0).r == 0u) return;

    uint w = fetchLocal(local);

    // Air voxels are left alone rather than cleared.
    //
    // This used to write black to all six faces, guarding against a slot keeping
    // the radiance of a block that has since been broken. That guard is
    // unnecessary: the cache is only ever read at a ray HIT, and scVoxelForHit
    // pulls the hit point half a voxel inward, so every read lands on an
    // OCCUPIED voxel. Stale radiance sitting in an air slot is unreachable -- it
    // cannot be returned to anyone, and the moment the slot is occupied again
    // the normal update path owns it. Six RGBA16F stores across ~90% of the
    // volume was the single largest source of write traffic in this pass, spent
    // entirely on writing zeroes over zeroes.
    //
    // One consequence worth knowing while debugging: GI_DEBUG_VIEW 4 and 6 read
    // the image without the tag, so they will now show leftovers in empty space.
    // Views 3 and 5, which respect the tag, are unaffected and remain the ones
    // to trust.
    if (voxelIsAir(w)) return;

    uint cat    = voxelCategory(w);
    vec3 albedo = voxelAlbedo(w);

    // Self-emission is a property of the block, not of any one face.
    vec3 emission = vec3(0.0);
    if (cat == VOXEL_LIGHT) {
        emission = emitterColor(voxelLightMat(w)) * float(GI_EMISSION);
    } else if (cat == VOXEL_EMISSIVE) {
        emission = albedo * float(GI_EMISSION) * SC_EMISSIVE_BOOST;
    }

    vec3  lightVec  = ptWorldLightVector();
    vec3  lightCol  = ptLightColor();
    float rain      = 1.0 - rainStrength * 0.75;
    float eyeAlt    = ptEyeAltitude();
    uint  vHash     = pcgHash(uint(wv.x * 73856093) ^ uint(wv.y * 19349663)
                            ^ uint(wv.z * 83492791));
    uint  seed      = pcgHash(vHash ^ uint(frameCounter) * 2654435761u);

    // Sky access, straight out of the voxel word.
    //
    // This replaces a traceVoxelOccluded() probe of SC_SKY_PROBE_DIST (64) blocks
    // cast PER FACE, per refresh -- the longest and most numerous ray in the
    // renderer, spent rediscovering a number Minecraft had already computed and
    // handed to the voxeliser. It is also a better answer than the probe was: the
    // probe fired one ray along a fixed skyward direction and thresholded it to
    // 0 or 1, so a face under partial cover read as fully open or fully blind,
    // whereas the lightmap is a real graduated occlusion value.
    //
    // Shaped with the same falloff the gather applies to its own sky term, so
    // the cache and the gather agree about how dark a cave is instead of the
    // cache quietly leaking daylight that the gather then faithfully reads back.
    float blockSky = pow(voxelSkylight(w), GI_SKY_LEAK_FALLOFF);

    // Which faces refresh this frame. Offsetting the rotation by the voxel hash
    // keeps neighbouring blocks from cycling in lockstep, which would otherwise
    // read as a pulse across a flat wall.
    uint faceRot = uint(frameCounter) + vHash;

    float tag = scTag(wv);

    for (int f = 0; f < SC_FACES; ++f) {
        vec3 n = scFaceNormal(f);

        // The previous value is needed for the temporal blend regardless, so
        // reading it first costs nothing and lets both gates below decide
        // whether the rest of this face's work is worth doing at all.
        vec4 prev  = imageLoad(faceRadianceImg, scImageCoord(wv, f));
        bool valid = abs(prev.a - tag) < 0.5;

        // Face round-robin: Lumen's per-frame card-capture budget, one level
        // down. A face already holding a valid estimate can skip a turn -- its
        // lighting moves slowly and SC_BLEND is a far longer time constant than
        // SC_FACE_STRIDE frames. A slot with no valid history must be filled
        // now, or it reads back black and the cache appears to have holes.
        #if SC_FACE_STRIDE > 1
        if (valid && ((uint(f) + faceRot) % uint(SC_FACE_STRIDE)) != 0u) continue;
        #endif

        // A face buried against a solid neighbour emits nothing: no ray can see
        // it, and lighting it would leak through a one-block partition whenever
        // a lookup landed on the wrong side. Only pay the store when it would
        // change something -- in the steady state a buried face is already black
        // with a matching tag, and rewriting that every refresh was most of what
        // remained of this pass's write traffic.
        if (!voxelIsAir(fetchLocal(local + scFaceOffset(f)))) {
            if (!valid || any(greaterThan(prev.rgb, vec3(0.0)))) scImageStore(wv, f, vec3(0.0));
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
        // Orient the block's sky access to this face. An upward face sees the
        // whole sky the block does; a sideways face sees roughly half of it; a
        // downward face -- a ceiling, the underside of an overhang -- sees almost
        // none, which is what SC_SKY_DOWN_FACE sets.
        //
        // This gating is what stops the cache leaking: a cave wall's bounce rays
        // nearly all die on SC_BOUNCE_DIST in open air, and charging them full
        // sky bakes daylight into cave geometry which the gather then faithfully
        // reads back out. Fixing only the gather would not have removed the leak.
        float faceSkyVis = blockSky * mix(SC_SKY_DOWN_FACE, 1.0, clamp(n.y * 0.5 + 0.5, 0.0, 1.0));

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

                // ONE level of feedback propagation, and only from the near
                // field. This keeps the surfaces that light what you are
                // standing next to warm even when the camera never looks at
                // them directly. Letting every updated voxel stamp would make
                // the requested set grow by SC_BOUNCE_DIST per frame and
                // saturate the cascade in about eight frames -- see the note in
                // surfaceCache.glsl. Near-field voxels refresh unconditionally,
                // so the shell they warm cannot itself propagate further.
                #ifdef SC_FEEDBACK
                if (nearField) scRequestAt(scVoxelForHit(h.pos, h.normal));
                #endif
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
        // different block's radiance. (prev/valid were read at the top of the
        // loop, where the round-robin gate also needed them.)
        vec3 outR = valid ? mix(prev.rgb, total, SC_BLEND) : total;

        scImageStore(wv, f, outR);
    }
}

void main() {
    // The full cascade-0 volume every frame. The per-voxel gates in updateVoxel
    // -- refresh budget first, then hierarchical occupancy -- are what make that
    // cheap, and they do a far better job than the old fixed Z-slab stride: they
    // skip empty space entirely rather than by the calendar, and they spend the
    // budget by distance instead of spreading it uniformly over a volume that is
    // mostly out of sight. A thread that bails costs a few ALU and two fetches
    // that never leave L1.
    uint total  = uint(SC_XZ * SC_Y * SC_XZ);
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
