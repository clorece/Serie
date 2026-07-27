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
#include "/lib/blocklightColors.glsl"
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
};

VoxelHit voxelHitMiss(vec3 worldPos, vec3 rayDir) {
    VoxelHit h;
    h.hit = false; h.pos = worldPos; h.normal = -rayDir;
    h.category = VOXEL_AIR; h.shapeId = 0u; h.albedo = vec3(0.0); h.lightMat = 0u;
    h.emission = vec3(0.0);
    h.escaped = false;
    return h;
}

// Radiance an emitter voxel contributes. Emitters store their material rather
// than an albedo, and take their colour from the blocklight palette.
vec3 voxelEmitterColor(uint w) {
    return (voxelCategory(w) == VOXEL_LIGHT)
         ? GetSpecialBlocklightColor(int(voxelLightMat(w))).rgb
         : voxelAlbedo(w);
}

// Steps allowed per cascade. Each cascade has the same voxel count, so one
// budget serves all of them -- a coarse cascade covers far more world per step.
// Driven by GI_MAX_STEPS so the existing "dense forest" performance knob still
// applies; the floor keeps a cascade from terminating before it can cross.
#define CASCADE_MAX_STEPS max(GI_MAX_STEPS, 64)

// ---------------------------------------------------------------------------
// Closest-hit traversal
// ---------------------------------------------------------------------------
VoxelHit traceVoxelCascaded(vec3 worldPos, vec3 rayDir, float maxDist, bool skipOrigin) {
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
        // range or the far side of this cascade.
        vec3 t0Box = (vec3(0.0) - localPos) * ird;
        vec3 t1Box = (vec3(CASCADE_DIMS) - localPos) * ird;
        vec3 tfBox = max(t0Box, t1Box);
        float tCascadeExit = min(tfBox.x, min(tfBox.y, tfBox.z));
        float tLimit = min((maxDist - tWorld) / vs, tCascadeExit);

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

        // Hand off to the next cascade just past this one's boundary.
        tWorld += max(tCascadeExit, 0.0) * vs + 1e-3;
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

// ---------------------------------------------------------------------------
// Any-hit traversal (shadow / occlusion rays)
//
// CURRENTLY UNUSED. Its only caller was the surface cache's per-face sky probe,
// which now reads the skylight banked in the voxel word instead. Kept because it
// is the natural any-hit primitive and Phase 3.4 reflections will want it -- but
// note before reusing it that it still has both open defects: the step-budget
// teleport fixed above in traceVoxelCascaded, and the torch asymmetry (this
// blocks on the whole voxel where traceVoxelCascaded resolves the light shape).
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

        for (int i = 0; i < CASCADE_MAX_STEPS; ++i) {
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
                #ifdef VOXEL_BLAS
                uint shapeId = (k == 0) ? voxelShape(w) : 0u;
                if (shapeId != 0u) {
                    if (occludeShape(shapeId, localPos - vec3(vox), rayDir, first, tLimit)) return true;
                } else
                #endif
                // BLAS off: any occupied voxel blocks as a full cube.
                if (!first) {
                    return true;
                }
            }

            bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
            tLocal   = min(tMax.x, min(tMax.y, tMax.z));
            tMax    += vec3(mask) * tDelta;
            vox     += stepDir * ivec3(mask);
            first    = false;
        }

        tWorld += max(tCascadeExit, 0.0) * vs + 1e-3;
        if (tWorld >= maxDist) break;
        first = false;
    }
    return false;
}

#endif
