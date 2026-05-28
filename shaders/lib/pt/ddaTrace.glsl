#ifndef DDA_TRACE_GLSL
#define DDA_TRACE_GLSL

#include "/lib/pt/voxelData.glsl"

// Screen-Space Ray Tracing Fallback (Optimized 2D Line March)
bool screenSpaceRayTrace(vec3 worldRayOrigin, vec3 worldRayDir, float maxDist, vec3 camPos, mat4 gbufferProj, mat4 gbufferMV, sampler2D depthtex0, float dither, out vec3 hitAlbedo, out vec3 hitNormal, out vec3 hitPos) {
    vec3 viewOrigin = (gbufferMV * vec4(worldRayOrigin - camPos, 1.0)).xyz;
    vec3 viewDir = mat3(gbufferMV) * worldRayDir;
    
    vec4 clipOrigin = gbufferProj * vec4(viewOrigin, 1.0);
    vec3 ndcOrigin = clipOrigin.xyz / clipOrigin.w;
    
    vec3 viewEnd = viewOrigin + viewDir * maxDist;
    vec4 clipEnd = gbufferProj * vec4(viewEnd, 1.0);
    if (clipEnd.w <= 0.0) return false; // Behind camera
    
    vec3 ndcEnd = clipEnd.xyz / clipEnd.w;
    
    vec3 uvOrigin = ndcOrigin * 0.5 + 0.5;
    vec3 uvEnd = ndcEnd * 0.5 + 0.5;
    
    vec3 rayDelta = uvEnd - uvOrigin;
    
    // 1. Pre-clip ray to screen boundaries to remove inner loop branching
    float tMax = 1.0;
    if (rayDelta.x > 0.0) tMax = min(tMax, (1.0 - uvOrigin.x) / rayDelta.x);
    else if (rayDelta.x < 0.0) tMax = min(tMax, -uvOrigin.x / rayDelta.x);
    if (rayDelta.y > 0.0) tMax = min(tMax, (1.0 - uvOrigin.y) / rayDelta.y);
    else if (rayDelta.y < 0.0) tMax = min(tMax, -uvOrigin.y / rayDelta.y);
    if (rayDelta.z > 0.0) tMax = min(tMax, (1.0 - uvOrigin.z) / rayDelta.z);
    else if (rayDelta.z < 0.0) tMax = min(tMax, -uvOrigin.z / rayDelta.z);
    
    if (tMax <= 0.0) return false;
    rayDelta *= tMax;
    
    // Scale steps by screen distance, max 16 steps due to dithering
    float screenDist = max(abs(rayDelta.x), abs(rayDelta.y));
    if (screenDist < 0.005) return false;
    
    float steps = clamp(screenDist * 100.0, 4.0, 16.0);
    vec3 stepDelta = rayDelta / steps;
    
    // 2. Dither the start position to hide stepping artifacts
    vec3 currentUV = uvOrigin + stepDelta * dither;
    
    // 3. Set up linear depth interpolation for accurate thickness testing
    float invZOrigin = 1.0 / viewOrigin.z;
    float invZEnd = 1.0 / viewEnd.z;
    float invZDelta = (invZEnd - invZOrigin) * tMax;
    float invZStep = invZDelta / steps;
    float currentInvZ = invZOrigin + invZStep * dither;
    
    // World space thickness tolerance (e.g. 1.0 meters/blocks)
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

        // Convert depth buffer to linear view space Z
        float ndcZ = depthBuffer * 2.0 - 1.0;
        float sceneViewZ = P32 / (-ndcZ - P22);
        
        float rayViewZ = 1.0 / currentInvZ;

        // Both sceneViewZ and rayViewZ are negative. Smaller value means further from camera.
        if (rayViewZ < sceneViewZ && rayViewZ > sceneViewZ - hitThickness) {
            hitPos = worldRayOrigin + worldRayDir * maxDist * tMax * (float(i) / steps); // approximate
            hitNormal = -worldRayDir; // Better fallback normal than vec3(0,1,0)
            return true;
        }
        
        currentUV += stepDelta;
        currentInvZ += invZStep;
    }
    return false;
}

// Amanatides-Woo DDA traversal through the voxel grid.
//
// atlas:    voxel atlas sampler (colortex7, bound as usampler2D)
// worldPos: ray origin in absolute world space (should be offset off the surface)
// rayDir:   normalized ray direction in world space
// maxDist:  maximum travel distance in blocks
// camPos:   current cameraPosition uniform value (grid anchor)
//
// Returns true if the ray hits VOXEL_OPAQUE or VOXEL_FOLIAGE before maxDist.
bool traceVoxelRay(
    usampler2D atlas,
    vec3 worldPos,
    vec3 rayDir,
    float maxDist,
    vec3 camPos,
    sampler2D depthtex0,
    mat4 gbufferProj,
    mat4 gbufferMV
) {
    vec3 gridOrigin = floor(camPos) - vec3(VOXEL_RADIUS);
    vec3 localPos   = worldPos - gridOrigin;

    // Fast check: if the origin is far outside the grid, skip the trace entirely.
    if (any(lessThan(localPos, vec3(-2.0))) || any(greaterThanEqual(localPos, vec3(VOXEL_GRID_SIZE + 2.0)))) {
        // Fallback to screen-space for rays starting outside voxel volume
        vec3 dummyA, dummyN, dummyP;
        return screenSpaceRayTrace(worldPos, rayDir, maxDist, camPos, gbufferProj, gbufferMV, depthtex0, 0.5, dummyA, dummyN, dummyP);
    }

    ivec3 vox     = ivec3(floor(localPos));
    ivec3 stepDir = ivec3(sign(rayDir));

    // Per-axis step size
    vec3 invRayDir = 1.0 / (rayDir + 1e-8);
    vec3 tDelta = abs(invRayDir);

    // Pre-calculate exact distance where the ray exits the voxel grid AABB.
    // This eliminates the need to check 3D bounds on every single step of the loop.
    vec3 t0 = (vec3(0.0) - localPos) * invRayDir;
    vec3 t1 = (vec3(VOXEL_GRID_SIZE) - localPos) * invRayDir;
    vec3 tMaxBox = max(t0, t1);
    float tExit = min(tMaxBox.x, min(tMaxBox.y, tMaxBox.z));

    // Distance to the first boundary crossing
    vec3 tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;

    float tEntry = 0.0;
    // Cap iterations to slightly more than the grid diameter
    for (int i = 0; i < 80; i++) {
        // Exit if we exceed the requested distance
        if (tEntry >= maxDist) return false;
        
        // Exit if we leave the active grid volume
        if (tEntry > tExit) {
            // Escape to screen-space fallback
            vec3 dummyA, dummyN, dummyP;
            return screenSpaceRayTrace(worldPos + rayDir * tEntry, rayDir, maxDist - tEntry, camPos, gbufferProj, gbufferMV, depthtex0, 0.5, dummyA, dummyN, dummyP);
        }

        uint vt = sampleVoxel(atlas, vox);
        if (vt != VOXEL_AIR && i > 0) return true;

        // Step to the nearest axis boundary
        bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
        tEntry = min(tMax.x, min(tMax.y, tMax.z));
        tMax  += vec3(mask) * tDelta;
        vox   += stepDir * ivec3(mask);
    }
    return false;
}

#endif
