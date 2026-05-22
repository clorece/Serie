#ifndef SCREENTRACE_GLSL
#define SCREENTRACE_GLSL

// ============================================================================
//  Screen-space path tracing — hybrid partner to the voxel DDA.
//  Marches a GI ray across the SCREEN against the depth buffer. A hit means the
//  ray ran into on-screen geometry, so the radiance can be read straight from the
//  previous-frame lit scene (colortex5). This captures everything the +-64 voxel
//  grid cannot: entities, non-full blocks (slabs/stairs/fences), sub-voxel
//  contact detail, and any geometry PAST the voxel bounds that is still on screen.
//  When the screen ray misses or leaves the frame, the caller falls back to the
//  voxel DDA (off-screen / inside-bounds coverage).
//
//  The march is uniform in SCREEN space (constant pixel stride) and interpolates
//  1/viewZ, which is perspective-linear along the projected ray. That keeps the
//  per-step depth change small at any distance (so the ray can't hop over whole
//  surfaces) and lets a small fixed step budget reach as far as the ray stays on
//  screen. A front->behind crossing within `thickness` is binary-refined to the
//  intersection.
// ============================================================================

// common.glsl provides getDepth; options.glsl provides the SSPT_* defaults.
#include "/lib/util/common.glsl"
#include "/lib/options.glsl"

// Project a view-space point to screen UV. Returns false if behind the camera.
bool projectToScreen(mat4 proj, vec3 viewPos, out vec2 uv) {
    vec4 clip = proj * vec4(viewPos, 1.0);
    if (clip.w <= 0.0) { uv = vec2(0.0); return false; }
    uv = clip.xy / clip.w * 0.5 + 0.5;
    return true;
}

// March viewOrigin -> viewOrigin + viewDir*maxDist (view space, -Z forward).
// On a hit, returns the occluder's GEOMETRIC screen UV + raw depth (caller
// reconstructs world pos with the unjittered proj inverse).
//   steps     : screen-space samples along the ray (then a short binary refine)
//   thickness : how far behind a surface (view-Z, ~blocks) still counts as a hit
//   dither    : [0,1) per-ray offset to break up march banding
//   jitterUV  : TAA jitter (buffer UV = geometric UV + jitterUV), added for depth taps
bool traceScreenSpace(sampler2D depthTex, mat4 proj,
                      vec3 viewOrigin, vec3 viewDir, float maxDist,
                      int steps, float thickness, float dither, vec2 jitterUV,
                      out vec2 hitUV, out float hitRaw) {
    hitUV  = vec2(0.0);
    hitRaw = 1.0;

    vec3 viewEnd = viewOrigin + viewDir * maxDist;

    // Clamp the far end to stay in front of the near plane (both z negative).
    const float zNear = -0.05;
    if (viewEnd.z > zNear) {
        float tClip = (zNear - viewOrigin.z) / (viewEnd.z - viewOrigin.z);
        viewEnd = mix(viewOrigin, viewEnd, clamp(tClip, 0.0, 1.0));
    }

    vec2 uv0, uv1;
    if (!projectToScreen(proj, viewOrigin, uv0)) return false;
    if (!projectToScreen(proj, viewEnd,    uv1)) return false;

    // Perspective-linear depth endpoints: 1/viewZ interpolates linearly in screen space.
    float iz0 = 1.0 / viewOrigin.z;   // negative
    float iz1 = 1.0 / viewEnd.z;

    float invSteps = 1.0 / float(steps);
    float sStart   = invSteps * (0.5 + dither);   // start a touch out to avoid self-hit

    float prevS        = 0.0;
    float prevDelta    = -1.0;            // start assumed in front of the scene
    float prevRayViewZ = viewOrigin.z;
    bool  havePrev     = false;

    for (int i = 0; i < steps; i++) {
        float s  = mix(sStart, 1.0, float(i) * invSteps);
        vec2  uv = mix(uv0, uv1, s);                       // geometric UV
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

        float rayViewZ = 1.0 / mix(iz0, iz1, s);           // perspective-correct ray depth
        float stepSpan = abs(rayViewZ - prevRayViewZ);     // this step's view-depth extent

        float sceneRaw = textureLod(depthTex, uv + jitterUV, 0.0).r;
        if (sceneRaw >= 1.0) { prevS = s; prevDelta = -1.0; prevRayViewZ = rayViewZ; havePrev = true; continue; } // sky

        float sceneViewZ = -getDepth(sceneRaw);            // scene surface depth (negative)
        float delta      = sceneViewZ - rayViewZ;          // > 0 : ray is BEHIND the surface

        // A surface accepts a hit up to its `thickness` PLUS this step's own depth span,
        // so far steps (which cover more view-depth per pixel) still register crossings.
        float effThick = thickness + stepSpan;

        // Front -> behind transition within the surface thickness = real intersection.
        if (havePrev && prevDelta < 0.0 && delta > 0.0 && delta < effThick) {
            float lo = prevS, hi = s;
            for (int b = 0; b < 5; b++) {
                float mid = 0.5 * (lo + hi);
                vec2  um  = mix(uv0, uv1, mid);
                float rz  = 1.0 / mix(iz0, iz1, mid);
                float sr  = textureLod(depthTex, um + jitterUV, 0.0).r;
                if ((-getDepth(sr)) - rz > 0.0) { hi = mid; uv = um; sceneRaw = sr; }
                else                            { lo = mid; }
            }
            hitUV  = uv;
            hitRaw = sceneRaw;
            return true;
        }

        prevS        = s;
        prevDelta    = delta;
        prevRayViewZ = rayViewZ;
        havePrev     = true;
    }
    return false;
}

#endif
