#ifndef DENOISE_GLSL
#define DENOISE_GLSL

// common.glsl provides texelSize and getDepth; options.glsl provides the SVGF sigmas.
#include "/lib/util/common.glsl"
#include "/lib/options.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

// YCoCg conversion (reversible, better for box-clamping than RGB)
vec3 RGBtoYCoCg(vec3 c) {
    return vec3(
         0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
         0.5  * c.r - 0.5 * c.b,
        -0.25 * c.r + 0.5 * c.g - 0.25 * c.b
    );
}
vec3 YCoCgtoRGB(vec3 c) {
    float tmp = c.x - c.z;
    return vec3(tmp + c.y, c.x + c.z, tmp - c.y);
}

// Neighborhood clamping (box clamp) to kill ghosts at the temporal accumulation source.
// We use a variance-based box clamp (mean +/- std * gamma).
// This is more relaxed than a strict min/max bound, allowing the temporal
// accumulation to actually build up a smooth signal from 1spp noise.
vec3 clipHistory(vec3 history, vec3 center, sampler2D currentTex, vec2 uv) {
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec3 c = RGBtoYCoCg(textureLod(currentTex, uv + vec2(x, y) * texelSize, 0.0).rgb);
            m1 += c; m2 += c * c;
        }
    }
    m1 /= 9.0; m2 /= 9.0;
    vec3 std = sqrt(max(m2 - m1 * m1, 0.0));
    
    // SAFETY CLAMP: Prevent standard deviation from exploding due to 1spp fireflies.
    // If std is infinite, the AABB is infinite, and stale history (ghosts) will never be rejected.
    std = min(std, m1 * 2.0);
    
    // Box clamp history to [mean - k*std, mean + k*std]
    vec3 h = RGBtoYCoCg(history);
    vec3 aabbMin = m1 - std * 1.5;
    vec3 aabbMax = m1 + std * 1.5;
    
    return YCoCgtoRGB(clamp(h, aabbMin, aabbMax));
}

// Custom 2x2 Bilateral History Fetch
// Evaluates depth and normal similarity for each of the 4 neighboring texels in 
// the history buffer and rejects those that belong to a different surface.
bool fetchBilateralHistory(
    vec2 uv, float expectedClipZ, vec3 expectedNormalWorld, 
    sampler2D hist8, sampler2D hist9, sampler2D hist15, 
    out vec4 outHistory8, out vec4 outHistory9
) {
    vec2 pos = uv * vec2(viewWidth, viewHeight) - 0.5;
    vec2 pos00 = floor(pos);
    vec2 f = pos - pos00;

    ivec2 i00 = ivec2(pos00);
    ivec2 i10 = i00 + ivec2(1, 0);
    ivec2 i01 = i00 + ivec2(0, 1);
    ivec2 i11 = i00 + ivec2(1, 1);

    vec4 w = vec4(
        (1.0 - f.x) * (1.0 - f.y),
        f.x * (1.0 - f.y),
        (1.0 - f.x) * f.y,
        f.x * f.y
    );

    vec4 c9_00 = texelFetch(hist9, i00, 0);
    vec4 c9_10 = texelFetch(hist9, i10, 0);
    vec4 c9_01 = texelFetch(hist9, i01, 0);
    vec4 c9_11 = texelFetch(hist9, i11, 0);

    // Hybrid depth validation
    float expectedLinDepth = getDepth(expectedClipZ * 0.5 + 0.5);
    bool isHand = (expectedLinDepth < 0.76); // Hand depth threshold
    
    vec4 validW;
    if (isHand) {
        // For the hand, use relative linear depth check to accommodate bobbing/sway
        vec4 linDepths = vec4(
            getDepth(c9_00.r),
            getDepth(c9_10.r),
            getDepth(c9_01.r),
            getDepth(c9_11.r)
        );
        vec4 relErr = abs(linDepths - vec4(expectedLinDepth)) / max(vec4(expectedLinDepth), vec4(1e-3));
        validW = step(relErr, vec4(0.15)); // Robust 15% relative threshold for the hand
    } else {
        // For terrain, use the original high-precision clip-space check to avoid quantization stripes
        vec4 clipZ = vec4(c9_00.r, c9_10.r, c9_01.r, c9_11.r) * 2.0 - 1.0;
        validW = step(abs(clipZ - expectedClipZ), vec4(0.005));
    }
    
    // Normal rejection: use world-space normal similarity to identify surface boundaries.
    vec3 n00 = octDecodeNormal(texelFetch(hist15, i00, 0).xy);
    vec3 n10 = octDecodeNormal(texelFetch(hist15, i10, 0).xy);
    vec3 n01 = octDecodeNormal(texelFetch(hist15, i01, 0).xy);
    vec3 n11 = octDecodeNormal(texelFetch(hist15, i11, 0).xy);
    
    vec4 normalW = vec4(
        max(dot(n00, expectedNormalWorld), 0.0),
        max(dot(n10, expectedNormalWorld), 0.0),
        max(dot(n01, expectedNormalWorld), 0.0),
        max(dot(n11, expectedNormalWorld), 0.0)
    );
    // Pow 16.0 provides a good balance between edge sharpness and noise stability.
    validW *= pow(normalW, vec4(16.0));
    
    w *= validW;

    float wSum = dot(w, vec4(1.0));
    if (wSum > 1e-5) {
        vec4 c8_00 = texelFetch(hist8, i00, 0);
        vec4 c8_10 = texelFetch(hist8, i10, 0);
        vec4 c8_01 = texelFetch(hist8, i01, 0);
        vec4 c8_11 = texelFetch(hist8, i11, 0);

        outHistory8 = (c8_00 * w.x + c8_10 * w.y + c8_01 * w.z + c8_11 * w.w) / wSum;
        outHistory9 = (c9_00 * w.x + c9_10 * w.y + c9_01 * w.z + c9_11 * w.w) / wSum;
        return true;
    }
    return false;
}

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
    
    // Increased epsilon (0.05 instead of 1e-3) prevents the denoiser from "freezing"
    // when variance drops, which causes the painterly/blotchy artifacts.
    float invSigmaL = 1.0 / (SVGF_SIGMA_L * sqrt(max(cVar, 0.0)) + 0.05);
    
    // Relaxed depth edge-stopping to allow angled surfaces to blur properly
    float invSigmaZ = 1.0 / (SVGF_SIGMA_Z * abs(centerDepth) * 0.02 + 1e-3);
    
    // Relaxed normal map stopping (caps at 16.0 instead of 64.0)
    float sigmaN = min(float(SVGF_SIGMA_N), 16.0);

    vec3  sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;

    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 off = vec2(x, y) * stepSize;
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
                float wn = pow(max(dot(nN, centerN), 0.0), sigmaN);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);
                
                w = hw * wz * wn * wl;

                #ifdef SVGF_WORLD_RADIUS
                    // Convert this tap's pixel offset to a world-space distance and
                    // fall off past SVGF_SIGMA_WORLD blocks. This prevents dark halos
                    // ("refractions") from bleeding across distant disjoint surfaces.
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
    
    float invSigmaL = 1.0 / (SVGF_SIGMA_L * sqrt(max(varG, 0.0)) + 0.05);
    float invSigmaZ = 1.0 / (SVGF_SIGMA_Z * abs(centerDepth) * 0.02 + 1e-3);
    float sigmaN = min(float(SVGF_SIGMA_N), 16.0);

    vec3  sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;

    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 off = vec2(x, y) * stepSize;
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
                float wn = pow(max(dot(nN, centerN), 0.0), sigmaN);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);

                w = hw * wz * wn * wl;

                #ifdef SVGF_WORLD_RADIUS
                    // Convert this tap's pixel offset to a world-space distance and
                    // fall off past SVGF_SIGMA_WORLD blocks. This prevents dark halos
                    // ("refractions") from bleeding across distant disjoint surfaces.
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
