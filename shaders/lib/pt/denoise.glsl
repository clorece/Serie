#ifndef DENOISE_GLSL
#define DENOISE_GLSL

// ============================================================================
//  SerieVX GI denoiser  (rebuilt from scratch)
// ----------------------------------------------------------------------------
//  Chain:  d0_restir (1spp estimate -> colortex3)
//          d0_accum   temporal accumulation        -> colortex8 (.rgb col, .a frames)
//                                                     colortex9 (.r LINEAR depth, .gb moments)
//          d1_prefilter variance estimate          -> colortex3 (.rgb col, .a variance)
//          d1..d6     a-trous spatial (steps 1..32) -> colortex3 (final, read by d7)
//
//  Design (modelled on iterationRP + MollyVX):
//   * Spatial edge-stops use PLANE DISTANCE  dot(viewPosA - viewPosB, normal): ~0 for
//     coplanar taps at ANY angle, so robust at grazing angles and never depth-bands.
//   * colortex9.r stores LINEAR depth (uniform 16F precision; raw depth banded the history).
//   * Variance is boosted while a pixel is young and decays as it converges, so the a-trous
//     fades toward an identity filter on settled pixels -> static detail / GI shadows kept.
//   * The temporal history (colortex8) stays the RAW accumulated signal; the a-trous filters
//     it fresh each frame for display, so the blur is never fed back / compounded.
// ============================================================================

// common.glsl provides texelSize, getDepth, far/near, oct*Normal, viewWidth/Height.
#include "/lib/util/common.glsl"
#include "/lib/options.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

#ifndef GBUFFER_PROJECTION_INVERSE_DECLARED
#define GBUFFER_PROJECTION_INVERSE_DECLARED
uniform mat4 gbufferProjectionInverse;
#endif

// View-space position from screen uv + raw (hyperbolic) depth.
vec3 getViewPos(vec2 uv, float rawDepth) {
    vec4 p = gbufferProjectionInverse * vec4(vec3(uv, rawDepth) * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

// World blocks spanned by one screen pixel per unit linear depth (vertical FOV term).
float pixelWorldPerDepth() {
    return 2.0 * gbufferProjectionInverse[1][1] * texelSize.y;
}

float varFromMoments(float m1, float m2) { return max(m2 - m1 * m1, 0.0); }

// ---------------------------------------------------------------------------
//  Per-pixel variance (d1_prefilter). moments: momTex.g = E[L], .b = E[L^2].
//  Young pixels also get a 3x3 spatial luma variance floor and a 1/(2^frames)
//  boost so fresh / disoccluded pixels filter hard; the boost vanishes once
//  converged, letting the a-trous relax and keep detail.
// ---------------------------------------------------------------------------
float estimateVariance(sampler2D giTex, sampler2D momTex, vec2 uv, float frames) {
    vec4  m   = textureLod(momTex, uv, 0.0);
    float var = varFromMoments(m.g, m.b);

    if (frames < 8.0) {
        float s1 = 0.0, s2 = 0.0;
        for (int x = -1; x <= 1; x++)
        for (int y = -1; y <= 1; y++) {
            float l = luma(textureLod(giTex, uv + vec2(x, y) * texelSize, 0.0).rgb);
            s1 += l; s2 += l * l;
        }
        s1 /= 9.0; s2 /= 9.0;
        var = max(var, max(s2 - s1 * s1, 0.0));
    }
    var += (m.g * m.g + 1e-4) / max(exp2(frames) - 1.0, 1e-4);
    return var;
}

// ---------------------------------------------------------------------------
//  One a-trous wavelet iteration. src = .rgb colour + .a variance.
//  depthTex/normalTex are CURRENT-frame geometry (depthtex0 / colortex1 view normals).
// ---------------------------------------------------------------------------
float atrousW(int i) { return (i == 0) ? 0.375 : (i == 1) ? 0.25 : 0.0625; }

vec4 atrousFilter(sampler2D src, sampler2D depthTex, sampler2D normalTex,
                  vec2 uv, float stepSize, float frames) {
    float cRawD = textureLod(depthTex, uv, 0.0).r;
    vec4  c     = textureLod(src, uv, 0.0);
    if (cRawD >= 1.0) return c;                        // sky: passthrough

    vec3  cPos   = getViewPos(uv, cRawD);
    float cDepth = getDepth(cRawD);
    vec3  cN     = normalize(textureLod(normalTex, uv, 0.0).rgb * 2.0 - 1.0);
    float cLum   = luma(c.rgb);

    float conv   = clamp(frames / float(DENOISE_MAX_FRAMES), 0.0, 1.0);

    // luminance edge-stop: variance guided, tightened as the pixel converges
    float phiLum  = mix(float(DENOISE_PHI_LUMA), float(DENOISE_PHI_LUMA) * 0.3, conv);
    float invSigL = 1.0 / (phiLum * sqrt(max(c.a, 0.0)) + 0.02);
    // plane-distance tolerance scales with the pixel's world footprint
    float footprint = pixelWorldPerDepth() * cDepth;
    float invSigZ   = 1.0 / (float(DENOISE_PHI_DEPTH) * (footprint + 0.02));
    float sigmaN    = float(DENOISE_PHI_NORMAL);

    // Centre starts at the B3-spline centre weight; converged pixels scale it up so the
    // un-blurred centre dominates -> keep detail / path-traced GI shadows once settled.
    float centerW = atrousW(0) * atrousW(0) * (1.0 + conv * (float(DENOISE_DETAIL) / 100.0) * 8.0);
    vec3  sumC = c.rgb * centerW;
    float sumV = c.a   * centerW * centerW;
    float wsum = centerW;

    for (int x = -2; x <= 2; x++)
    for (int y = -2; y <= 2; y++) {
        if (x == 0 && y == 0) continue;
        vec2 nUV = uv + vec2(x, y) * stepSize * texelSize;
        if (clamp(nUV, 0.0, 1.0) != nUV) continue;

        float nRawD = textureLod(depthTex, nUV, 0.0).r;
        if (nRawD >= 1.0) continue;

        vec4 n    = textureLod(src, nUV, 0.0);
        vec3 nPos = getViewPos(nUV, nRawD);
        vec3 nN   = normalize(textureLod(normalTex, nUV, 0.0).rgb * 2.0 - 1.0);

        float planeDist = abs(dot(cPos - nPos, cN));     // coplanar -> ~0 at any angle
        float wz = exp(-planeDist * invSigZ);
        float wn = pow(max(dot(nN, cN), 0.0), sigmaN);
        float wl = exp(-abs(cLum - luma(n.rgb)) * invSigL);
        float hw = atrousW(abs(x)) * atrousW(abs(y));

        float w = hw * wz * wn * wl;
        sumC += n.rgb * w;
        sumV += n.a   * w * w;
        wsum += w;
    }
    return vec4(sumC / wsum, sumV / (wsum * wsum));
}

#endif
