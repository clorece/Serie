#ifndef DDA_TRACE_GLSL
#define DDA_TRACE_GLSL

#include "/lib/pt/voxelData.glsl"

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
    vec3 camPos
) {
    vec3 gridOrigin = floor(camPos) - vec3(VOXEL_RADIUS);
    vec3 localPos   = worldPos - gridOrigin;

    // Fast check: if the origin is far outside the grid, skip the trace entirely.
    // The grid is centered on camera, so localPos should be within [0, VOXEL_GRID_SIZE].
    if (any(lessThan(localPos, vec3(-2.0))) || any(greaterThanEqual(localPos, vec3(VOXEL_GRID_SIZE + 2.0)))) return false;

    ivec3 vox     = ivec3(floor(localPos));
    ivec3 stepDir = ivec3(sign(rayDir));

    // Per-axis step size
    vec3 invRayDir = 1.0 / (abs(rayDir) + 1e-8);
    vec3 tDelta = invRayDir;

    // Distance to the first boundary crossing
    vec3 tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * (1.0 / (rayDir + 1e-8));

    float tEntry = 0.0;
    // Cap iterations to slightly more than the grid diameter
    for (int i = 0; i < 80; i++) {
        // Exit if we exceed the requested distance or leave the active grid volume
        if (tEntry >= maxDist) break;
        if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(VOXEL_GRID_SIZE)))) break;

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
