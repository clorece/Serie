#ifndef DENOISE_GLSL
#define DENOISE_GLSL

// common.glsl provides texelSize and getDepth; options.glsl provides the SVGF sigmas.
#include "/lib/util/common.glsl"
#include "/lib/options.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

// ============================================================================
//  SVGF — Spatiotemporal Variance-Guided Filtering (Schied et al. 2017),
//  re-implemented from the published algorithm.
//
//  The temporal stage (in d0_restir) integrates colour and the first two
//  luminance moments. Here we estimate per-pixel variance from those moments
//  (or spatially while history is short), then run an edge-aware a-trous
//  wavelet whose LUMINANCE edge-stopping is scaled by sqrt(variance): noisy
//  regions blur hard, converged regions keep detail. Variance is filtered
//  alongside colour (with weight^2) so later iterations stay guided.
//
//  Buffer convention through the chain: .rgb = irradiance, .a = variance.
// ============================================================================

// B3-spline (1,4,6,4,1)/16 a-trous kernel weight, indexed by |offset| in 0..2.
float atrousW(int i) {
    return (i == 0) ? (6.0 / 16.0) : (i == 1) ? (4.0 / 16.0) : (1.0 / 16.0);
}

float varFromMoments(float m1, float m2) {
    return max(m2 - m1 * m1, 0.0);
}

// Spatial luminance variance over a 5x5 window (used to bootstrap young pixels
// that don't yet have enough temporal samples for a reliable moment estimate).
float spatialLumaVariance(sampler2D colorTex, vec2 uv) {
    float s1 = 0.0, s2 = 0.0, count = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            float l = luma(textureLod(colorTex, uv + vec2(x, y) * texelSize, 0.0).rgb);
            s1 += l; s2 += l * l; count += 1.0;
        }
    }
    s1 /= count; s2 /= count;
    return max(s2 - s1 * s1, 0.0);
}

// 3x3 gaussian of the variance channel — stabilises the luminance weight so a
// single noisy pixel doesn't punch a hole through the edge-stopping.
float gauss3Var(sampler2D src, vec2 uv) {
    float v = 0.0, wsum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            float w = ((x == 0) ? 2.0 : 1.0) * ((y == 0) ? 2.0 : 1.0);
            v += textureLod(src, uv + vec2(x, y) * texelSize, 0.0).a * w;
            wsum += w;
        }
    }
    return v / wsum;
}

// ---- First a-trous iteration -------------------------------------------------
// Colour comes from giTex (.rgb); variance is derived here from momentTex
// (.g = m1, .b = m2) or estimated spatially while the history is short.
// Returns vec4(filtered colour, filtered variance) to seed the chain.
vec4 svgfAtrousFirst(
    sampler2D giTex, sampler2D momentTex, sampler2D depthTex, sampler2D normalTex,
    vec2 uv, float stepSize, float centerDepth, vec2 depthGrad, vec3 centerN, float histLen,
    float pxWorld
) {
    vec3  cColor = textureLod(giTex, uv, 0.0).rgb;
    float cLuma  = luma(cColor);
    vec4  cm     = textureLod(momentTex, uv, 0.0);
    float cVar   = varFromMoments(cm.g, cm.b);
    if (histLen < float(SVGF_VAR_BOOST)) {
        float sv = spatialLumaVariance(giTex, uv);
        cVar = max(cVar, sv) * (1.0 + (float(SVGF_VAR_BOOST) - histLen));
    }
    
    float invSigmaL = 1.0 / (SVGF_SIGMA_L * sqrt(max(cVar, 0.0)) + 1e-3);
    float invSigmaZ = 1.0 / (SVGF_SIGMA_Z * abs(centerDepth) * 0.05 + 1e-2);

    // Break up banding with noise-based tap jitter
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    float ang = noise * 6.2831853;
    vec2  jitter = vec2(cos(ang), sin(ang)) * 0.25;

    vec3  sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;

    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 off = vec2(x, y) * stepSize + jitter;
            vec2 nUV = uv + off * texelSize;
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            vec3  nColor = textureLod(giTex, nUV, 0.0).rgb;
            vec4  nm     = textureLod(momentTex, nUV, 0.0);
            float nLuma  = luma(nColor);
            float nDepth = getDepth(textureLod(depthTex, nUV, 0.0).r);
            vec3  nN     = normalize(textureLod(normalTex, nUV, 0.0).rgb * 2.0 - 1.0);

            float hw = atrousW(abs(x)) * atrousW(abs(y));
            float w;
            if (x == 0 && y == 0) {
                w = hw;
            } else {
                float expectedD = centerDepth + dot(depthGrad, off);
                float wz = exp(-abs(nDepth - expectedD) * invSigmaZ);
                float wn = pow(max(dot(nN, centerN), 0.0), SVGF_SIGMA_N);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);
                #ifdef PT_DETAIL_RECONSTRUCT
                    float planeDelta = nDepth - expectedD;
                    float contact = step(nLuma, cLuma)
                                  * smoothstep(0.0, abs(centerDepth) * 0.03 + 1e-3, planeDelta)
                                  * (1.0 - smoothstep(0.0, 4.0, length(off)));
                    w = hw * mix(wz * wn * wl, 1.0, contact);
                #else
                    w = hw * wz * wn * wl;
                #endif
                #ifdef SVGF_WORLD_RADIUS
                    // Convert this tap's pixel offset to a world-space distance and
                    // fall off past SVGF_SIGMA_WORLD blocks.
                    float tangential = length(off) * pxWorld * abs(centerDepth);
                    float worldDist  = sqrt(tangential * tangential
                                          + (nDepth - expectedD) * (nDepth - expectedD));
                    w *= exp(-worldDist / SVGF_SIGMA_WORLD);
                #endif
            }
            sumC += nColor * w;
            sumV += varFromMoments(nm.g, nm.b) * w * w;
            wsum += w;
        }
    }
    return vec4(sumC / max(wsum, 1e-5), sumV / max(wsum * wsum, 1e-5));
}

// ---- Subsequent a-trous iterations ------------------------------------------
vec4 svgfAtrous(
    sampler2D src, sampler2D depthTex, sampler2D normalTex,
    vec2 uv, float stepSize, float centerDepth, vec2 depthGrad, vec3 centerN,
    float pxWorld
) {
    vec4  c      = textureLod(src, uv, 0.0);
    float cLuma  = luma(c.rgb);
    float varG   = gauss3Var(src, uv);
    
    float invSigmaL = 1.0 / (SVGF_SIGMA_L * sqrt(max(varG, 0.0)) + 1e-3);
    float invSigmaZ = 1.0 / (SVGF_SIGMA_Z * abs(centerDepth) * 0.05 + 1e-2);

    // Break up banding with noise-based tap jitter
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    float ang = noise * 6.2831853;
    vec2  jitter = vec2(cos(ang), sin(ang)) * 0.25;

    vec3  sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;

    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 off = vec2(x, y) * stepSize + jitter;
            vec2 nUV = uv + off * texelSize;
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            vec4  n      = textureLod(src, nUV, 0.0);
            float nLuma  = luma(n.rgb);
            float nDepth = getDepth(textureLod(depthTex, nUV, 0.0).r);
            vec3  nN     = normalize(textureLod(normalTex, nUV, 0.0).rgb * 2.0 - 1.0);

            float hw = atrousW(abs(x)) * atrousW(abs(y));
            float w;
            if (x == 0 && y == 0) {
                w = hw;
            } else {
                float expectedD = centerDepth + dot(depthGrad, off);
                float wz = exp(-abs(nDepth - expectedD) * invSigmaZ);
                float wn = pow(max(dot(nN, centerN), 0.0), SVGF_SIGMA_N);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);
                #ifdef PT_DETAIL_RECONSTRUCT
                    float planeDelta = nDepth - expectedD;
                    float contact = step(nLuma, cLuma)
                                  * smoothstep(0.0, abs(centerDepth) * 0.03 + 1e-3, planeDelta)
                                  * (1.0 - smoothstep(0.0, 4.0, length(off)));
                    w = hw * mix(wz * wn * wl, 1.0, contact);
                #else
                    w = hw * wz * wn * wl;
                #endif
                #ifdef SVGF_WORLD_RADIUS
                    float tangential = length(off) * pxWorld * abs(centerDepth);
                    float worldDist  = sqrt(tangential * tangential
                                          + (nDepth - expectedD) * (nDepth - expectedD));
                    w *= exp(-worldDist / SVGF_SIGMA_WORLD);
                #endif
            }
            sumC += n.rgb * w;
            sumV += n.a   * w * w;
            wsum += w;
        }
    }
    return vec4(sumC / max(wsum, 1e-5), sumV / max(wsum * wsum, 1e-5));
}

#endif
