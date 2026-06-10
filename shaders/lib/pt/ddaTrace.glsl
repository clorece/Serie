#ifndef DDA_TRACE_GLSL
#define DDA_TRACE_GLSL

#include "/lib/pt/voxelData.glsl"

bool screenSpaceRayTrace(vec3 worldRayOrigin, vec3 worldRayDir, float maxDist, vec3 camPos, mat4 gbufferProj, mat4 gbufferMV, sampler2D depthtex0, float dither, out vec2 hitUV, out vec3 hitNormal, out vec3 hitPos) {
    vec3 viewOrigin = (gbufferMV * vec4(worldRayOrigin - camPos, 1.0)).xyz;
    vec3 viewDir = mat3(gbufferMV) * worldRayDir;
    
    vec4 clipOrigin = gbufferProj * vec4(viewOrigin, 1.0);
    vec3 ndcOrigin = clipOrigin.xyz / clipOrigin.w;
    
    vec3 viewEnd = viewOrigin + viewDir * maxDist;
    vec4 clipEnd = gbufferProj * vec4(viewEnd, 1.0);

    
    vec3 ndcEnd = clipEnd.xyz / clipEnd.w;
    
    vec3 uvOrigin = ndcOrigin * 0.5 + 0.5;
    vec3 uvEnd = ndcEnd * 0.5 + 0.5;
    
    vec3 rayDelta = uvEnd - uvOrigin;
    
    float tMax = 1.0;
    if (rayDelta.x > 0.0) tMax = min(tMax, (1.0 - uvOrigin.x) / rayDelta.x);
    else if (rayDelta.x < 0.0) tMax = min(tMax, -uvOrigin.x / rayDelta.x);
    if (rayDelta.y > 0.0) tMax = min(tMax, (1.0 - uvOrigin.y) / rayDelta.y);
    else if (rayDelta.y < 0.0) tMax = min(tMax, -uvOrigin.y / rayDelta.y);
    if (rayDelta.z > 0.0) tMax = min(tMax, (1.0 - uvOrigin.z) / rayDelta.z);
    else if (rayDelta.z < 0.0) tMax = min(tMax, -uvOrigin.z / rayDelta.z);
    
    if (tMax <= 0.0) return false;
    rayDelta *= tMax;

    float screenDist = max(abs(rayDelta.x), abs(rayDelta.y));
    if (screenDist < 0.005) return false;
    
    float steps = clamp(screenDist * 100.0, 4.0, 16.0);
    vec3 stepDelta = rayDelta / steps;
    
    vec3 currentUV = uvOrigin + stepDelta * dither;

    float invZOrigin = 1.0 / viewOrigin.z;
    float invZEnd = 1.0 / viewEnd.z;
    float invZDelta = (invZEnd - invZOrigin) * tMax;
    float invZStep = invZDelta / steps;
    float currentInvZ = invZOrigin + invZStep * dither;
    

    float hitThickness = 1.0; 
    float P22 = gbufferProj[2][2];
    float P32 = gbufferProj[3][2];
    
    for (int i = 0; i < int(steps); i++) {
        float depthBuffer = textureLod(depthtex0, currentUV.xy, 0.0).r;
        if (depthBuffer >= 1.0) {
            currentUV += stepDelta;
            currentInvZ += invZStep;
            continue;
        }

        float ndcZ = depthBuffer * 2.0 - 1.0;
        float sceneViewZ = P32 / (-ndcZ - P22);
        
        float rayViewZ = 1.0 / currentInvZ;
        float prevRayViewZ = 1.0 / (currentInvZ - invZStep);

        float hitThickness = max(1.0, abs(sceneViewZ) * 0.05);
        if ((rayViewZ < sceneViewZ && prevRayViewZ >= sceneViewZ) || 
            (rayViewZ < sceneViewZ && rayViewZ > sceneViewZ - hitThickness)) {
            hitPos = worldRayOrigin + worldRayDir * maxDist * tMax * (float(i) / steps);
            hitNormal = -worldRayDir; // Better fallback normal than vec3(0,1,0)
            hitUV = currentUV.xy;
            return true;
        }
        
        currentUV += stepDelta;
        currentInvZ += invZStep;
    }
    return false;
}

// `allowSS` enables the screen-space ray-trace fallback when the ray leaves the
// voxel grid. With the grid now covering a 256-block radius this is only kept
// for RTAO (short contact rays); GI shadow / sky-probe rays pass false and just
// treat out-of-grid as unoccluded (the voxel grid is the source of truth).
bool traceVoxelRay(
    usampler3D atlas,
    vec3 worldPos,
    vec3 rayDir,
    float maxDist,
    vec3 camPos,
    sampler2D depthtex0,
    mat4 gbufferProj,
    mat4 gbufferMV,
    bool allowSS
) {
    vec3 gridOrigin = floor(camPos) - VOXEL_RADIUS_VEC;
    vec3 localPos   = worldPos - gridOrigin;

    if (any(lessThan(localPos, vec3(-2.0))) || any(greaterThanEqual(localPos, vec3(VOXEL_DIMS) + 2.0))) {
        if (!allowSS) return false;
        vec2 dummyUV; vec3 dummyN, dummyP;
        return screenSpaceRayTrace(worldPos, rayDir, maxDist, camPos, gbufferProj, gbufferMV, depthtex0, 0.5, dummyUV, dummyN, dummyP);
    }

    ivec3 vox     = ivec3(floor(localPos));
    ivec3 stepDir = ivec3(sign(rayDir));


    vec3 invRayDir = 1.0 / (rayDir + 1e-8);
    vec3 tDelta = abs(invRayDir);

    vec3 t0 = (vec3(0.0) - localPos) * invRayDir;
    vec3 t1 = (vec3(VOXEL_DIMS) - localPos) * invRayDir;
    vec3 tMaxBox = max(t0, t1);
    float tExit = min(tMaxBox.x, min(tMaxBox.y, tMaxBox.z));

    // ray-direction sign as a 0/1 selector for the brick exit face
    vec3 dirPos = step(0.0, rayDir);

    vec3 tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;

    float tEntry = 0.0;
    // generous cap; rays terminate far earlier via maxDist / tExit / brick-skips
    for (int i = 0; i < 768; i++) {
        if (tEntry >= maxDist) return false;

        if (tEntry > tExit) {
            if (!allowSS) return false;
            vec2 dummyUV; vec3 dummyN, dummyP;
            return screenSpaceRayTrace(worldPos + rayDir * tEntry, rayDir, maxDist - tEntry, camPos, gbufferProj, gbufferMV, depthtex0, 0.5, dummyUV, dummyN, dummyP);
        }

        // --- hierarchical empty-space skip (64³ super-brick, then 8³ brick) ---
        // If the cell around `vox` is provably empty, advance straight to its
        // exit face (skipping up to ~110 / ~14 voxel steps) instead of marching it.
        // Single in-grid test shared by both levels (out-of-grid falls through
        // to a normal fine step, matching brickIsEmpty's old bounds semantics).
        if (all(greaterThanEqual(vox, ivec3(0))) && all(lessThan(vox, VOXEL_DIMS))) {
            if (texelFetch(superBrickSampler, vox >> 6, 0).r == 0u) {
                vec3 cellMin = vec3((vox >> 6) << 6);
                vec3 tb = (mix(cellMin, cellMin + float(VOXEL_SUPER), dirPos) - localPos) * invRayDir;
                float tCellExit = min(tb.x, min(tb.y, tb.z));
                tEntry = tCellExit;
                // land just past the exit face, then reseed the fine DDA from there
                vox  = ivec3(floor(localPos + rayDir * (tCellExit + 1e-3)));
                tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;
                continue;
            }
            if (texelFetch(brickSampler, vox >> 3, 0).r == 0u) {
                vec3 brickMin = vec3((vox >> 3) << 3);
                vec3 tb = (mix(brickMin, brickMin + float(VOXEL_BRICK), dirPos) - localPos) * invRayDir;
                float tBrickExit = min(tb.x, min(tb.y, tb.z));
                tEntry = tBrickExit;
                vox  = ivec3(floor(localPos + rayDir * (tBrickExit + 1e-3)));
                tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;
                continue;
            }
        }

        uint vt = sampleVoxel(atlas, vox);

        // all non-air voxels (including all blocklights) act as solid occluders for shadow rays
        if (vt != VOXEL_AIR && i > 0) return true;

        bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
        tEntry = min(tMax.x, min(tMax.y, tMax.z));
        tMax  += vec3(mask) * tDelta;
        vox   += stepDir * ivec3(mask);
    }
    return false;
}

#endif
