#ifndef GTAO_GLSL
#define GTAO_GLSL

// ============================================================================
//  Ground-Truth Ambient Occlusion (Jimenez et al. 2016)
// ----------------------------------------------------------------------------
//  Short-radius screen-space AO that COMPLEMENTS the voxel GI. The voxel grid
//  (1 block/voxel) captures macro occlusion through the GI integral but cannot
//  resolve sub-voxel contact darkening (inside corners, slabs/stairs nestling,
//  block-edge crevices). GTAO fills exactly that gap. Keep GTAO_RADIUS small so
//  it adds only contact detail and never re-darkens what the GI already did.
//
//  Produces a scalar AO term plus a view-space bent normal (the average
//  unoccluded direction), which lets the GI-off path light skylight
//  directionally. Adapted from the horizon-scan formulation; uses the pack's
//  gbufferProjection(Inverse) for view<->screen transforms.
// ============================================================================

#ifndef PI
#define PI 3.14159265359
#endif
#define GTAO_HALF_PI 1.57079632679

uniform mat4 gbufferProjection;
// NOTE: the including pass must declare `uniform mat4 gbufferProjectionInverse;` and the
// `texelSize` macro (from common.glsl) before this file is included.

float gtaoFastAcos(float x) {
    float a = abs(x);
    float r = (-0.156583 * a + GTAO_HALF_PI) * sqrt(max(1.0 - a, 0.0));
    return x >= 0.0 ? r : PI - r;
}

vec3 gtaoViewPosFromDepth(vec2 uv, float depth) {
    vec4 p = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

vec2 gtaoViewToScreen(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return (clip.xy / clip.w) * 0.5 + 0.5;
}

float gtaoIntegrateArc(vec2 h, float n, float cosN) {
    vec2 t = cosN + 2.0 * h * sin(n) - cos(2.0 * h - n);
    return 0.25 * (t.x + t.y);
}

// March one direction in screen space and return the maximum horizon angle.
float gtaoHorizon(
    sampler2D depthTex,
    vec3 viewSliceDir,
    vec3 viewerDir,
    vec2 screenPos,
    vec3 viewPos,
    float dither
) {
    float stepSize = (GTAO_RADIUS / float(GTAO_HORIZON_STEPS));

    vec2 screenStep = gtaoViewToScreen(viewPos + viewSliceDir * stepSize);
    vec2 rayStep    = screenStep - screenPos;

    // Skip degenerate steps (direction nearly parallel to the view plane edge).
    float stepLen = length(rayStep);
    if (stepLen < 1e-6) return GTAO_HALF_PI;

    vec2 rayPos = screenPos + rayStep * (dither + texelSize.x / stepLen);

    float maxCos = -1.0;
    for (int i = 0; i < GTAO_HORIZON_STEPS; ++i, rayPos += rayStep) {
        if (rayPos.x < 0.0 || rayPos.x > 1.0 || rayPos.y < 0.0 || rayPos.y > 1.0) break;

        float d = textureLod(depthTex, rayPos, 0.0).r;
        if (d >= 1.0) continue;

        vec3 offset = gtaoViewPosFromDepth(rayPos, d) - viewPos;
        float lenSq = dot(offset, offset);
        if (lenSq < 1e-8) continue;
        float norm = inversesqrt(lenSq);

        // Distance falloff: fade samples beyond the radius back to "no occluder".
        float dist     = lenSq * norm; // == length(offset)
        float falloff  = clamp((dist - GTAO_FALLOFF * GTAO_RADIUS)
                               / max(GTAO_RADIUS * (1.0 - GTAO_FALLOFF), 1e-4), 0.0, 1.0);

        float cosTheta = dot(viewerDir, offset) * norm;
        cosTheta = mix(cosTheta, -1.0, falloff);

        maxCos = max(maxCos, cosTheta);
    }
    return gtaoFastAcos(clamp(maxCos, -1.0, 1.0));
}

// Returns AO in [0,1] (1 = fully lit) and writes a view-space bent normal.
float computeGtao(
    sampler2D depthTex,
    vec3  viewPos,
    vec3  viewNormal,
    vec2  uv,
    vec2  dither,        // .x = slice rotation, .y = horizon march jitter
    out vec3 bentNormalView
) {
    vec3 viewerDir   = normalize(-viewPos);
    vec3 viewerRight = normalize(cross(vec3(0.0, 1.0, 0.0), viewerDir));
    vec3 viewerUp    = cross(viewerDir, viewerRight);
    mat3 localToView = mat3(viewerRight, viewerUp, viewerDir);
    vec2 screenPos   = uv;

    float ao = 0.0;
    bentNormalView = vec3(0.0);

    for (int s = 0; s < GTAO_SLICES; ++s) {
        float sliceAngle = (float(s) + dither.x) * (PI / float(GTAO_SLICES));
        // Slice direction in the plane perpendicular to the view vector.
        vec3 sliceDir = localToView * vec3(cos(sliceAngle), sin(sliceAngle), 0.0);

        vec3 axis            = cross(sliceDir, viewerDir);
        vec3 projectedNormal = viewNormal - axis * dot(viewNormal, axis);

        float projLenSq = dot(projectedNormal, projectedNormal);
        if (projLenSq < 1e-8) continue;
        float projNorm = inversesqrt(projLenSq);

        float sgnGamma = sign(dot(sliceDir, projectedNormal));
        float cosGamma = clamp(dot(projectedNormal, viewerDir) * projNorm, 0.0, 1.0);
        float gamma    = sgnGamma * gtaoFastAcos(cosGamma);

        vec2 h;
        h.x = gtaoHorizon(depthTex, -sliceDir, viewerDir, screenPos, viewPos, dither.y);
        h.y = gtaoHorizon(depthTex,  sliceDir, viewerDir, screenPos, viewPos, dither.y);

        // Clamp horizons to the hemisphere around the projected normal.
        h = gamma + clamp(vec2(-1.0, 1.0) * h - gamma, -GTAO_HALF_PI, GTAO_HALF_PI);

        ao += gtaoIntegrateArc(h, gamma, cosGamma) * projLenSq * projNorm;

        float bentAngle = dot(h, vec2(0.5));
        bentNormalView += viewerDir * cos(bentAngle) + sliceDir * sin(bentAngle);
    }

    ao *= 1.0 / float(GTAO_SLICES);

#ifdef AO_MULTIBOUNCE
    const float albedo = 0.2; // approximate surrounding albedo
    ao /= albedo * ao + (1.0 - albedo);
#endif

    bentNormalView = normalize(bentNormalView - 0.5 * viewerDir);
    return clamp(ao, 0.0, 1.0);
}

#endif
