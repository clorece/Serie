#ifndef DH_GLSL
#define DH_GLSL

// Shared Distant Horizons helpers for the DEFERRED / COMPOSITE passes only.
// (Do NOT include this from dh_terrain/dh_water — Iris injects dhProjection*,
// dhMaterialId, etc. into those LOD programs, so re-declaring them collides.)
// Iris binds these reserved uniforms in any non-DH program that declares them;
// when the mod is off the depth textures read 1.0, so every guard is inert.

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

// True when a vanilla-sky pixel actually has DH LOD geometry behind it.
bool isDhPixel(float vanillaDepth, vec2 scaledUV) {
    return vanillaDepth >= 1.0 && texture(dhDepthTex0, scaledUV).r < 1.0;
}

// View-space position of a DH fragment. ndcUV = LOGICAL (full-res) uv, dhd = DH
// depth sampled at the matching render-scaled uv. DH shares the camera view
// matrix, so only the projection differs.
vec3 dhViewPos(vec2 ndcUV, float dhd) {
    vec4 v = dhProjectionInverse * vec4(ndcUV * 2.0 - 1.0, dhd * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

// Screen-space sun shadow marched against the DH opaque depth buffer. Gives
// distant LOD terrain self-shadowing (mountains over valleys) far past the
// vanilla shadow map, which only covers shadowDistance. viewPos + lightDirView
// are VIEW space; returns 0 (occluded) .. 1 (lit).
float dhScreenShadow(vec3 viewPos, vec3 lightDirView, float dither) {
    const int STEPS = 16;
    float rayLen = 128.0; // blocks toward the sun
    vec3  stepV  = lightDirView * (rayLen / float(STEPS));
    // Start a step out + dithered to break up banding and avoid self-hit.
    vec3  rayPos = viewPos + lightDirView * 1.5 + stepV * dither;

    for (int i = 0; i < STEPS; i++) {
        rayPos += stepV;

        vec4 clip = dhProjection * vec4(rayPos, 1.0);
        if (clip.w <= 0.0) break;
        vec3 ndc = clip.xyz / clip.w;
        vec2 uv  = ndc.xy * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

        float sceneDepth = texture(dhDepthTex1, uv * renderScale).r;
        if (sceneDepth >= 1.0) continue; // sky along the ray — no occluder

        vec4 sv = dhProjectionInverse * vec4(ndc.xy, sceneDepth * 2.0 - 1.0, 1.0);
        float sampleZ = sv.z / sv.w;

        float zDiff     = sampleZ - rayPos.z; // >0 means occluder in front of the ray
        float thickness = 6.0 + abs(rayPos.z) * 0.02;
        if (zDiff > 0.3 && zDiff < thickness) return 0.0;
    }
    return 1.0;
}
#endif // DISTANT_HORIZONS

#endif // DH_GLSL
