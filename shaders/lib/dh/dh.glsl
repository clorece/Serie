#ifndef DH_GLSL
#define DH_GLSL

// Shared Distant Horizons helpers for the DEFERRED / COMPOSITE passes only.
// (Do NOT include this from dh_terrain/dh_water — Iris injects dhProjection*,
// dhMaterialId, etc. into those LOD programs, so re-declaring them collides.)
// Iris binds these reserved uniforms in any non-DH program that declares them.
// When DH rendering is disabled at runtime, the depth textures may be unset or
// cleared instead of a useful 1.0 sky depth, so callers must pass through the
// runtime/depth validity helpers below.

const float DH_DEPTH_EPS = 1e-6;

bool isVanillaSkyDepth(float vanillaDepth) {
    return vanillaDepth >= 1.0 - DH_DEPTH_EPS;
}

#ifdef DISTANT_HORIZONS
uniform sampler2D dhDepthTex0;     // LOD depth incl. translucents (mirrors depthtex0)
uniform sampler2D dhDepthTex1;     // LOD depth opaque-only        (mirrors depthtex1)
uniform mat4 dhProjection;
uniform mat4 dhProjectionInverse;
uniform mat4 dhPreviousProjection;
uniform float dhNearPlane;
uniform float dhFarPlane;
uniform float dhRenderDistance;

// scaledUV = render-scaled screen uv (the convention the rest of the pack samples
// depthtex with). Returns the DH opaque+translucent depth there.
float dhSampleDepth(vec2 scaledUV) { return texture(dhDepthTex0, scaledUV).r; }

// The shader option can be compiled on while DH rendering is disabled in-game.
// In that state Iris may leave the reserved DH depth sampler unset/cleared instead
// of as a clean 1.0 texture. Treat DH as active only when its runtime uniforms look
// sane, and only accept plausible nonzero depth values from the DH depth buffer.
bool dhRuntimeActive() {
    return dhRenderDistance > 0.0 && dhFarPlane > dhNearPlane + 1.0;
}

bool isDhDepthValue(float dhDepth) {
    return dhDepth > DH_DEPTH_EPS && dhDepth < 1.0 - DH_DEPTH_EPS;
}

// True when a vanilla-sky pixel actually has DH LOD geometry behind it.
bool isDhPixel(float vanillaDepth, vec2 scaledUV) {
    if (!isVanillaSkyDepth(vanillaDepth) || !dhRuntimeActive()) return false;
    return isDhDepthValue(dhSampleDepth(scaledUV));
}

// View-space position of a DH fragment. ndcUV = LOGICAL (full-res) uv, dhd = DH
// depth sampled at the matching render-scaled uv. DH shares the camera view
// matrix, so only the projection differs.
vec3 dhViewPos(vec2 ndcUV, float dhd) {
    vec4 v = dhProjectionInverse * vec4(ndcUV * 2.0 - 1.0, dhd * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

// Screen-space sun shadow marched against the DH depth buffer. Gives distant LOD
// terrain self-shadowing (mountains over valleys) far past the vanilla shadow
// map, which only covers shadowDistance. viewPos / viewNormal / lightDirView are
// VIEW space; returns 0 (occluded) .. 1 (lit). Mirrors the near getInfiniteShadows
// far-path parameters so the look is continuous across the LOD boundary.
//
// Samples dhDepthTex0 (depth incl. translucents): it is always populated (the
// position reconstruction relies on it), whereas dhDepthTex1 proved unreliable in
// this setup — using it here made the shadows patchy ("not everything shadowed").
// Distant water/glass counting as an occluder is negligible.
float dhScreenShadow(vec3 viewPos, vec3 viewNormal, vec3 lightDirView, float dither) {
    const int STEPS = 32;
    float viewDist = length(viewPos);
    float rayLen   = 128.0; // blocks toward the sun (matches the near far-shadow ray)
    vec3  stepV    = lightDirView * (rayLen / float(STEPS));
    float stepLen  = length(stepV);

    // Push off the surface along its normal (distance-scaled) so the ray separates
    // from the start surface — without this, at LOD distance the ray hugs the
    // surface and never detects an occluder (the patchiness the user saw).
    float nBias  = 0.2 + viewDist * 0.0025;
    vec3  rayPos = viewPos + viewNormal * nBias + stepV * dither;

    float thickness     = max(stepLen * 1.5, 8.0);
    float distTolerance = 0.05 + abs(viewPos.z) * 0.001;

    for (int i = 0; i < STEPS; i++) {
        rayPos += stepV;

        vec4 clip = dhProjection * vec4(rayPos, 1.0);
        if (clip.w <= 0.0) break;
        vec3 ndc = clip.xyz / clip.w;
        vec2 uv  = ndc.xy * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

        float sceneDepth = texture(dhDepthTex0, uv * renderScale).r;
        if (isVanillaSkyDepth(sceneDepth)) continue; // sky along the ray — no occluder

        vec4 sv = dhProjectionInverse * vec4(ndc.xy, sceneDepth * 2.0 - 1.0, 1.0);
        float sampleZ = sv.z / sv.w;

        float zDiff = sampleZ - rayPos.z; // >0 means occluder in front of the ray
        if (zDiff > distTolerance && zDiff < thickness) {
            // Early hits (near occluder) = solid shadow; late hits fade out.
            return smoothstep(0.55, 1.0, float(i) / float(STEPS));
        }
    }
    return 1.0;
}
#endif // DISTANT_HORIZONS

#endif // DH_GLSL
