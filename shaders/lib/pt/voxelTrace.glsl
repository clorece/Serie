#ifndef VOXEL_TRACE_GLSL
#define VOXEL_TRACE_GLSL

// ---------------------------------------------------------------------------
// Cascaded voxel traversal.
//
// A ray walks cascade 0 at full resolution until it leaves that volume, then
// picks up in cascade 1 from the exit point, and so on. Each cascade is a plain
// DDA with two levels of empty-space skipping (8^3 bricks, 64^3 super-bricks).
//
// Sub-block geometry is resolved only in cascade 0, where a voxel is one block
// and the BLAS box list means something. Coarser cascades treat any occupied
// voxel as solid, which slightly over-occludes at distance -- the safe direction,
// and invisible for indirect light hundreds of blocks away.
// ---------------------------------------------------------------------------

#include "/lib/pt/voxelCascade.glsl"
#include "/lib/pt/blas.glsl"
#include "/lib/pt/lightShapes.glsl"
#include "/lib/pt/emitterPalette.glsl"
#include "/lib/pt/entityBvh.glsl"

struct VoxelHit {
    bool  hit;
    vec3  pos;       // world-space hit point
    vec3  normal;    // surface normal of the face entered
    uint  category;
    uint  shapeId;
    vec3  albedo;
    uint  lightMat;  // valid when category == VOXEL_LIGHT
    vec3  emission;  // gathered from emitters the ray passed through without being blocked
    // Why the ray missed, which is NOT the same question as whether it missed.
    // true  -> it left the cascades entirely: nothing else can occlude it, so the
    //          sky is the correct answer.
    // false -> it ran out of maxDist while still inside the grid. The sky is NOT
    //          the answer; the far field is simply unknown from here. Treating
    //          this as sky is what floods a cave with skylight, because in a
    //          large cave almost every ray exhausts its budget without ever
    //          touching geometry.
    bool  escaped;
    // Which cascade RESOLVED the hit, or -1 on a miss.
    //
    // This is not the same as "which cascade contains h.pos", and reading the
    // surface cache at the latter is wrong. A hit resolved in cascade 2 sits on a
    // 4-block voxel face; the cascade-0 voxel there is very likely AIR, because a
    // coarse voxel counts as occupied if ANY block inside it is. Looking that up
    // at cascade 0 lands on an empty slot and reads black. The cache must be
    // asked at the resolution the geometry was found at.
    int   cascade;
};

VoxelHit voxelHitMiss(vec3 worldPos, vec3 rayDir) {
    VoxelHit h;
    h.hit = false; h.pos = worldPos; h.normal = -rayDir;
    h.category = VOXEL_AIR; h.shapeId = 0u; h.albedo = vec3(0.0); h.lightMat = 0u;
    h.emission = vec3(0.0);
    h.escaped = false;
    h.cascade = -1;
    return h;
}

// Radiance an emitter voxel contributes. Emitters store their material rather
// than an albedo, and take their colour from the blocklight palette -- read here
// as a flat table lookup rather than by re-walking the ~160-line branch tree
// that builds it. See lib/pt/emitterPalette.glsl for why that matters inside
// this loop specifically.
vec3 voxelEmitterColor(uint w) {
    return (voxelCategory(w) == VOXEL_LIGHT)
         ? emitterColor(voxelLightMat(w))
         : voxelAlbedo(w);
}

// Steps allowed per cascade. Each cascade has the same voxel count, so one
// budget serves all of them -- a coarse cascade covers far more world per step.
// Driven by GI_MAX_STEPS so the existing "dense forest" performance knob still
// applies; the floor keeps a cascade from terminating before it can cross.
#define CASCADE_MAX_STEPS max(GI_MAX_STEPS, 64)

// ---------------------------------------------------------------------------
// Cone stepping (Phase 3.2)
//
// Lumen's software tracer widens its cone with distance and samples coarser SDF
// mips. The voxel analogue is to promote a ray to a coarser cascade by how far
// it has TRAVELLED, not only by which box it has left.
//
// The gain is large and purely geometric. A 48-block gather ray used to walk
// cascade 0 -- one block per step -- for its entire length, up to 83 steps.
// Promoting at 16 blocks and again at 32 puts the last two thirds of the ray on
// 2- and 4-block voxels and brings the same 48 blocks in at roughly 32 steps.
//
// This was BLOCKED until the surface cache covered coarser cascades. Promotion
// is only sound if there is radiance stored where the ray now resolves its hit;
// against a cascade-0-only cache every promoted ray came back black, which is
// precisely why the pre-3.2 tracer could not do this.
//
// coneBase is the distance at which cascade 0 gives way, doubling per cascade.
// Zero disables promotion entirely, which is what a mirror reflection wants: it
// needs sharp geometry at range, and it casts few enough rays to afford it.
//
// The LAST cascade a ray may be promoted into is never capped -- neither the
// coarsest one nor, more importantly, the last one the surface cache covers.
// Capping it would leave the ray stopped in mid-grid with nowhere to be promoted
// to, walking out of the cascade loop while `escaped` claimed it had reached open
// sky: the exact shape of the step-budget teleport defect this pack already paid
// for once.
float coneCascadeLimit(float coneBase, int k) {
    if (coneBase <= 0.0 || k >= VOXEL_CASCADES - 1 || k >= SC_CASCADES - 1) return 3.0e38;
    return coneBase * float(1 << k);
}

// Finest cascade a ray that has already travelled `t` is still allowed to use.
//
// CLAMPED TO THE SURFACE CACHE'S COVERAGE, and that clamp is the correctness
// condition for this whole mechanism: promoting a ray into a cascade the cache
// does not store means its hit resolves against radiance that was never written,
// and every such ray comes back black. Promotion buys speed only where there is
// something to resolve against, so it stops where SC_CASCADES stops.
//
// A ray can still reach a coarser cascade the ordinary way, by physically
// leaving cascade SC_CASCADES-1's box -- 512 blocks out at the defaults. Callers
// detect that from VoxelHit.cascade and route it to the far field instead.
int coneMinCascade(float coneBase, float t) {
    if (coneBase <= 0.0) return 0;
    int k = 0;
    for (int i = 0; i < VOXEL_CASCADES - 1; ++i) {
        if (t >= coneBase * float(1 << i)) k = i + 1;
    }
    return min(k, SC_CASCADES - 1);
}

// ---------------------------------------------------------------------------
// Closest-hit traversal
// ---------------------------------------------------------------------------
VoxelHit traceVoxelCascadedCone(vec3 worldPos, vec3 rayDir, float maxDist, bool skipOrigin,
                                float coneBase) {
    VoxelHit miss = voxelHitMiss(worldPos, rayDir);

    // Entity hits compete with voxel hits on distance, so clip the voxel march
    // to the nearest entity and let it win if nothing closer turns up.
    float entityT = maxDist;
    vec3  entityN = -rayDir;
    bool  entityHit = false;
    #ifdef ENTITY_SHADOWS
    entityHit = entityBvhClosest(worldPos, rayDir, maxDist, entityT, entityN);
    if (entityHit) maxDist = min(maxDist, entityT);
    #endif

    int k = cascadeFor(worldPos);
    if (k < 0) {
        if (entityHit) {
            miss.hit = true;
            miss.pos = worldPos + rayDir * entityT;
            miss.normal = entityN;
            miss.category = VOXEL_OPAQUE;
            miss.albedo = vec3(0.5); // entity albedo is not captured; neutral grey
            // Entities are not in the voxel grid, so no cascade resolved this.
            // Callers treat cascade -1 as "no cached radiance here" and fall back.
            miss.cascade = -1;
        } else {
            // The origin is outside every cascade, so there is no voxel data that
            // could ever occlude this ray: the sky is the right answer.
            miss.escaped = true;
        }
        return miss;
    }

    float tWorld = 0.0;  // distance travelled in world units so far
    bool  first  = skipOrigin;
    vec3  accumEmission = vec3(0.0);
    // Set when a cascade's step budget runs out with range to spare. See the
    // handling below the inner loop -- this is what stops the ray teleporting
    // over geometry it never examined.
    bool  starved = false;

    for (; k < VOXEL_CASCADES; ++k) {
        // Cone promotion. A ray that has already run far enough is not allowed
        // back into a fine cascade: skipping straight to the right one avoids
        // spinning through iterations whose distance budget is already spent.
        // Coarser cascades are concentric supersets of finer ones, so the entry
        // point is still inside the promoted box by construction.
        k = max(k, coneMinCascade(coneBase, tWorld));

        float vs   = cascadeVoxelSize(k);
        vec3  org  = cascadeOrigin(k);
        vec3  entryWorld = worldPos + rayDir * tWorld;
        vec3  localPos   = (entryWorld - org) / vs;

        // Nudge inside when re-entering from a coarser boundary.
        if (any(lessThan(localPos, vec3(0.0))) || any(greaterThanEqual(localPos, vec3(CASCADE_DIMS)))) {
            continue;
        }

        ivec3 vox     = ivec3(floor(localPos));
        ivec3 stepDir = ivec3(sign(rayDir));
        vec3  ird     = 1.0 / (rayDir + vec3(1e-8));
        vec3  tDelta  = abs(ird);
        vec3  dirPos  = step(0.0, rayDir);

        // Local-space distance budget: whichever comes first, the ray's own
        // range, the distance at which the cone widens past this cascade, or the
        // far side of the cascade itself.
        vec3 t0Box = (vec3(0.0) - localPos) * ird;
        vec3 t1Box = (vec3(CASCADE_DIMS) - localPos) * ird;
        vec3 tfBox = max(t0Box, t1Box);
        float tCascadeExit = min(tfBox.x, min(tfBox.y, tfBox.z));
        float tCapWorld    = min(maxDist, coneCascadeLimit(coneBase, k));
        float tLimit = min((tCapWorld - tWorld) / vs, tCascadeExit);

        vec3 tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;

        float tLocal = 0.0;
        vec3  lastMask = vec3(0.0);
        ivec3 lastBrick = ivec3(-1);

        // i is declared outside the loop so the exit reason survives it: reaching
        // CASCADE_MAX_STEPS means the budget ran out, whereas any break means the
        // ray genuinely finished this cascade.
        int i = 0;
        for (; i < CASCADE_MAX_STEPS; ++i) {
            if (tLocal > tLimit) break;
            if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, CASCADE_DIMS))) break;

            // --- empty-space skipping -------------------------------------
            ivec3 curBrick = vox >> 3;
            if (curBrick != lastBrick) {
                if (texelFetch(superBrickSampler, cascadeSuperCoord(vox, k), 0).r == 0u) {
                    vec3 cellMin = vec3((vox >> 6) << 6);
                    vec3 tb = (mix(cellMin, cellMin + float(CASC_SUPER), dirPos) - localPos) * ird;
                    float tExit = min(tb.x, min(tb.y, tb.z));
                    lastMask = vec3(lessThanEqual(tb, vec3(tExit)));
                    tLocal = tExit;
                    vox  = ivec3(floor(localPos + rayDir * (tExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;
                    first = false;
                    continue;
                }
                if (texelFetch(brickSampler, cascadeBrickCoord(vox, k), 0).r == 0u) {
                    vec3 brickMin = vec3(curBrick << 3);
                    vec3 tb = (mix(brickMin, brickMin + float(CASC_BRICK), dirPos) - localPos) * ird;
                    float tExit = min(tb.x, min(tb.y, tb.z));
                    lastMask = vec3(lessThanEqual(tb, vec3(tExit)));
                    tLocal = tExit;
                    vox  = ivec3(floor(localPos + rayDir * (tExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;
                    first = false;
                    continue;
                }
                lastBrick = curBrick;
            }

            // --- voxel test ------------------------------------------------
            uint w = texelFetch(voxelSampler, cascadeAtlasCoord(vox, k), 0).r;
            if (!voxelIsAir(w)) {
                uint cat    = voxelCategory(w);
                bool isEmis = voxelIsEmissive(w);
                vec3 localRo = localPos - vec3(vox);

                float tHitLocal = tLocal;
                vec3  nHit      = -vec3(stepDir) * lastMask;
                bool  realHit   = true;
                float occT      = 0.0;

                // Sub-block geometry exists only where a voxel is one block.
                // Emitters take their silhouette from the material; every other
                // block indexes the generated BLAS table.
                bool hasShape = false;
                if (k == 0) {
                    if (cat == VOXEL_LIGHT) {
                        float tS; vec3 nS;
                        if (intersectLightShape(voxelLightMat(w), localRo, rayDir, first, tS, nS)) {
                            realHit = true; tHitLocal = tS; nHit = nS; occT = tS;
                        } else {
                            realHit = false;
                        }
                        vec3 dummyMin, dummyMax;
                        hasShape = lightOccluderAabb(voxelLightMat(w), dummyMin, dummyMax);
                        if (!hasShape) realHit = !first; // area emitter fills the voxel
                    } else {
                        #ifdef VOXEL_BLAS
                        uint shapeId = voxelShape(w);
                        if (shapeId != 0u) {
                            hasShape = true;
                            float tS; vec3 nS;
                            realHit = intersectShape(shapeId, localRo, rayDir, first, tS, nS);
                            occT = tS;
                            if (realHit) { tHitLocal = tS; nHit = nS; }
                        } else
                        #endif
                        // BLAS off: every non-emitter traces as a full cube, so the
                        // hit keeps the DDA's own tLocal and lastMask face normal.
                        if (first) {
                            realHit = false; // do not self-shadow on the origin block
                        }
                    }
                } else if (first) {
                    realHit = false;
                }

                // Emitters glow whether or not they block: a ray passing beside
                // a torch still picks up its flame.
                if (isEmis) {
                    float f = (cat == VOXEL_LIGHT)
                            ? lightEmisFactor(voxelLightMat(w), localRo, rayDir, realHit, occT, hasShape)
                            : (realHit ? 1.0 : 0.35);
                    accumEmission += voxelEmitterColor(w) * float(GI_EMISSION) * f;
                }

                if (realHit && tHitLocal <= tLimit) {
                    VoxelHit h;
                    h.hit      = true;
                    h.pos      = worldPos + rayDir * (tWorld + tHitLocal * vs);
                    h.normal   = nHit;
                    h.category = cat;
                    h.shapeId  = (k == 0) ? voxelShape(w) : 0u;
                    h.albedo   = voxelAlbedo(w);
                    h.lightMat = voxelLightMat(w);
                    h.emission = accumEmission;
                    h.escaped  = false; // it hit something; nothing escaped
                    h.cascade  = k;     // resolve the cache at THIS resolution
                    return h;
                }
            }

            bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
            lastMask = vec3(mask);
            tLocal   = min(tMax.x, min(tMax.y, tMax.z));
            tMax    += vec3(mask) * tDelta;
            vox     += stepDir * ivec3(mask);
            first    = false;
        }

        // Out of step budget with range still left in this cascade.
        //
        // The old code fell straight through to the hand-off below, which
        // advanced tWorld to the cascade's FAR SIDE and resumed in the next one
        // -- silently skipping every voxel in between. That leaked light in
        // exactly the dense geometry that exhausts the budget, and it also made
        // escaped optimistic, so the caller substituted full sky for a ray that
        // had actually stopped inside a forest canopy.
        //
        // Stop where the ray really is and mark it starved. The caller then
        // treats it as "the far field is unknown from here" and applies its own
        // sky-visibility gate, which is the same conservative answer a ray that
        // merely ran out of maxDist gets. This is what makes GI_MAX_STEPS a
        // usable performance knob: lowering it now costs reach, not correctness.
        if (i == CASCADE_MAX_STEPS) {
            starved = true;
            tWorld += tLocal * vs;
            break;
        }

        // Hand off to the next cascade just past whichever limit bound this one:
        // its own far boundary, or the cone's promotion distance. tLimit is
        // already the minimum of the two (and of the ray's remaining range), so
        // advancing by it is correct for all three cases -- and unlike the old
        // unconditional jump to tCascadeExit, it never advances the ray past
        // world the cone cap meant to hand to a coarser cascade rather than skip.
        tWorld += max(tLimit, 0.0) * vs + 1e-3;
        if (tWorld >= maxDist) break;
        first = false;
    }

    // No voxel hit inside maxDist; an entity box may still be the answer.
    if (entityHit) {
        miss.hit = true;
        miss.pos = worldPos + rayDir * entityT;
        miss.normal = entityN;
        miss.category = VOXEL_OPAQUE;
        miss.albedo = vec3(0.5);
        miss.emission = accumEmission;
        miss.cascade = -1;
        return miss;
    }
    // Distinguish the ways to miss. Falling out of the cascade loop means the
    // ray walked past the coarsest cascade with budget to spare -- it is out in
    // the open and the sky is correct. Stopping because tWorld caught maxDist,
    // or because a cascade's step budget ran out, means the ray died inside the
    // grid and knows nothing about what lies beyond, so the caller must NOT
    // substitute the sky.
    //
    // The starved case used to be indistinguishable from the first: the ray
    // teleported to the cascade boundary and reported escaped, which is how the
    // step-budget defect turned into a light leak. It is now explicit.
    miss.escaped = !starved && tWorld < maxDist;
    miss.pos = worldPos + rayDir * min(tWorld, maxDist);
    miss.emission = accumEmission;
    return miss;
}

// Default entry point: cone stepping at the pack-wide setting. Diffuse callers
// (the final gather, the surface cache's bounce loop, the radiance cache probes)
// all want this. Reflections call the cone form directly with a base derived
// from roughness, because a near-mirror must not lose detail with distance.
VoxelHit traceVoxelCascaded(vec3 worldPos, vec3 rayDir, float maxDist, bool skipOrigin) {
    #ifdef GI_CONE_STEP
        return traceVoxelCascadedCone(worldPos, rayDir, maxDist, skipOrigin, float(GI_CONE_BASE));
    #else
        return traceVoxelCascadedCone(worldPos, rayDir, maxDist, skipOrigin, 0.0);
    #endif
}

// ---------------------------------------------------------------------------
// Any-hit traversal (shadow / occlusion rays)
//
// Both defects the handoff listed against this function are fixed here, since
// Phase 3.4 was the stated deadline for them:
//
//   STEP-BUDGET TELEPORT. A ray that exhausted CASCADE_MAX_STEPS used to fall
//   through to the hand-off below, which advanced tWorld to the far side of the
//   cascade and resumed in the next -- so an any-hit ray could report "clear"
//   for a span it never examined, in exactly the dense geometry that exhausts
//   the budget. It now returns OCCLUDED instead. That is the conservative
//   direction for an any-hit query, and it is also the likely answer: brick and
//   super-brick skipping mean open air costs almost no steps, so burning 96 of
//   them is itself evidence of dense geometry. Over-occluding at distance is the
//   same trade the coarse cascades already make.
//
//   TORCH ASYMMETRY. traceVoxelCascaded resolves an emitter through its light
//   shape -- a torch is a 2/16 stick -- while this blocked on the whole voxel,
//   so shadow rays and GI rays disagreed about the same torch. Emitters now go
//   through intersectLightShape here too, and area emitters (no occluder box)
//   keep filling their voxel.
// ---------------------------------------------------------------------------
bool traceVoxelOccluded(vec3 worldPos, vec3 rayDir, float maxDist, bool skipOrigin) {
    // Entities live outside the voxel grid entirely, so they get their own test.
    // Doing it first is the cheap ordering: the tree is tiny and usually empty,
    // and a hit here skips the whole DDA.
    #ifdef ENTITY_SHADOWS
    if (entityBvhOccluded(worldPos, rayDir, maxDist)) return true;
    #endif

    int k = cascadeFor(worldPos);
    if (k < 0) return false;

    float tWorld = 0.0;
    bool  first  = skipOrigin;

    for (; k < VOXEL_CASCADES; ++k) {
        float vs  = cascadeVoxelSize(k);
        vec3  org = cascadeOrigin(k);
        vec3  localPos = (worldPos + rayDir * tWorld - org) / vs;
        if (any(lessThan(localPos, vec3(0.0))) || any(greaterThanEqual(localPos, vec3(CASCADE_DIMS)))) {
            continue;
        }

        ivec3 vox     = ivec3(floor(localPos));
        ivec3 stepDir = ivec3(sign(rayDir));
        vec3  ird     = 1.0 / (rayDir + vec3(1e-8));
        vec3  tDelta  = abs(ird);
        vec3  dirPos  = step(0.0, rayDir);

        vec3 t0Box = (vec3(0.0) - localPos) * ird;
        vec3 t1Box = (vec3(CASCADE_DIMS) - localPos) * ird;
        vec3 tfBox = max(t0Box, t1Box);
        float tCascadeExit = min(tfBox.x, min(tfBox.y, tfBox.z));
        float tLimit = min((maxDist - tWorld) / vs, tCascadeExit);

        vec3 tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;
        float tLocal = 0.0;
        ivec3 lastBrick = ivec3(-1);

        // Declared outside the loop so the exit reason survives it, exactly as in
        // traceVoxelCascaded: reaching CASCADE_MAX_STEPS means the budget ran
        // out, any break means the ray genuinely finished this cascade.
        int i = 0;
        for (; i < CASCADE_MAX_STEPS; ++i) {
            if (tLocal > tLimit) break;
            if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, CASCADE_DIMS))) break;

            ivec3 curBrick = vox >> 3;
            if (curBrick != lastBrick) {
                if (texelFetch(superBrickSampler, cascadeSuperCoord(vox, k), 0).r == 0u) {
                    vec3 cellMin = vec3((vox >> 6) << 6);
                    vec3 tb = (mix(cellMin, cellMin + float(CASC_SUPER), dirPos) - localPos) * ird;
                    float tExit = min(tb.x, min(tb.y, tb.z));
                    tLocal = tExit;
                    vox  = ivec3(floor(localPos + rayDir * (tExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;
                    first = false;
                    continue;
                }
                if (texelFetch(brickSampler, cascadeBrickCoord(vox, k), 0).r == 0u) {
                    vec3 brickMin = vec3(curBrick << 3);
                    vec3 tb = (mix(brickMin, brickMin + float(CASC_BRICK), dirPos) - localPos) * ird;
                    float tExit = min(tb.x, min(tb.y, tb.z));
                    tLocal = tExit;
                    vox  = ivec3(floor(localPos + rayDir * (tExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * ird;
                    first = false;
                    continue;
                }
                lastBrick = curBrick;
            }

            uint w = texelFetch(voxelSampler, cascadeAtlasCoord(vox, k), 0).r;
            if (!voxelIsAir(w)) {
                vec3 localRo = localPos - vec3(vox);
                if (k == 0 && voxelCategory(w) == VOXEL_LIGHT) {
                    // Emitter silhouettes are independent of VOXEL_BLAS and stay
                    // live, so resolve them the same way the closest-hit tracer
                    // does. Without this a torch occludes as a solid cubic metre
                    // here while casting a stick-shaped shadow there.
                    uint  lm = voxelLightMat(w);
                    float tS; vec3 nS;
                    if (intersectLightShape(lm, localRo, rayDir, first, tS, nS)) {
                        if (tS <= tLimit) return true;
                    } else {
                        vec3 dmin, dmax;
                        // No occluder box at all -> an area emitter (glowstone,
                        // lava) that fills its voxel and blocks like one.
                        if (!lightOccluderAabb(lm, dmin, dmax) && !first) return true;
                    }
                } else {
                    #ifdef VOXEL_BLAS
                    uint shapeId = (k == 0) ? voxelShape(w) : 0u;
                    if (shapeId != 0u) {
                        if (occludeShape(shapeId, localRo, rayDir, first, tLimit)) return true;
                    } else
                    #endif
                    // BLAS off: any occupied voxel blocks as a full cube.
                    if (!first) {
                        return true;
                    }
                }
            }

            bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
            tLocal   = min(tMax.x, min(tMax.y, tMax.z));
            tMax    += vec3(mask) * tDelta;
            vox     += stepDir * ivec3(mask);
            first    = false;
        }

        // Out of step budget with range still left. See the header: report
        // OCCLUDED rather than teleporting past a span this ray never looked at.
        if (i == CASCADE_MAX_STEPS) return true;

        tWorld += max(tCascadeExit, 0.0) * vs + 1e-3;
        if (tWorld >= maxDist) break;
        first = false;
    }
    return false;
}

#endif
