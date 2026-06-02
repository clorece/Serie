#ifndef DENOISE_GLSL
#define DENOISE_GLSL

#ifndef FRAME_COUNTER_DECLARE
#define FRAME_COUNTER_DECLARE
#endif

#include "/lib/util/common.glsl"
#include "/lib/options.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

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

    std = min(std, m1 * 2.0);
    
    // Box clamp history to [mean - k*std, mean + k*std]
    vec3 h = RGBtoYCoCg(history);
    vec3 aabbMin = m1 - std * 1.5;
    vec3 aabbMax = m1 + std * 1.5;
    
    return YCoCgtoRGB(clamp(h, aabbMin, aabbMax));
}

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

    float expectedLinDepth = getDepth(expectedClipZ * 0.5 + 0.5);
    bool isHand = (expectedLinDepth < 0.76); // hand depth threshold
    
    vec4 validW;
    if (isHand) {
        // for the hand, use relative linear depth check to accommodate bobbing/sway
        vec4 linDepths = vec4(
            getDepth(c9_00.r),
            getDepth(c9_10.r),
            getDepth(c9_01.r),
            getDepth(c9_11.r)
        );
        vec4 relErr = abs(linDepths - vec4(expectedLinDepth)) / max(vec4(expectedLinDepth), vec4(1e-3));
        validW = step(relErr, vec4(0.15)); // change 0.15 (15%) relative threshold for the hand
    } else {
        vec4 clipZ = vec4(c9_00.r, c9_10.r, c9_01.r, c9_11.r) * 2.0 - 1.0;
        validW = step(abs(clipZ - expectedClipZ), vec4(0.005));
    }

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

float atrousW(int i) {
    return (i == 0) ? (6.0 / 16.0) : (i == 1) ? (4.0 / 16.0) : (1.0 / 16.0);
}

float varFromMoments(float m1, float m2) {
    return max(m2 - m1 * m1, 0.0);
}

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

// À-trous kernel rotation, PHASE-LOCKED to the TAA jitter cycle.
// Two independent problems are addressed:
//   * SPATIAL: the old version quantized to 8x8-pixel blocks (`floor(uv*viewSize/8.0)`),
//     so at the large dilations of d2/d3/d4 (4/8/16) the per-block-constant rotation left
//     discontinuities at block borders -> a distance-based grid/maze. We use a per-pixel
//     base angle instead (no block structure).
//   * TEMPORAL: the old version animated the rotation on `frame % 64`. TAA jitters on a
//     `frame % 8` cycle (see getTaaJitter), so a 64-frame rotation beating against the
//     8-frame TAA cycle never settled inside TAA's ~20-frame memory -> the edge blur
//     changed every frame = refraction-like shimmer on block edges. We cycle the temporal
//     component in lock-step with TAA (period 8, even 45-deg steps). Each pixel then
//     repeats the SAME 8 orientations every 8 frames, so TAA (and the GI history) converge
//     to their rotational average -> stable, while staying spatially decorrelated.
float getJitterRotation(vec2 uv, int frame) {
    vec2 p = uv * vec2(viewWidth, viewHeight);
    float perPixel = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) * 6.2831853;
    float taaPhase = float(frame % 8) * (6.2831853 / 8.0); // locked to the TAA jitter period
    return perPixel + taaPhase;
}

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
    
    float invSigmaL = 1.0 / (SVGF_SIGMA_L * sqrt(max(cVar, 0.0)) + 0.05);
    float invSigmaZ = 1.0 / (SVGF_SIGMA_Z * abs(centerDepth) * 0.02 + 1e-3);
    float sigmaN = min(float(SVGF_SIGMA_N), 16.0);

    vec3  sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;

    mat2 rot = mat2(1.0, 0.0, 0.0, 1.0);
    int tapRange = 2;

    if (stepSize > 2.0) {
        float rotAngle = getJitterRotation(uv, frameCounter);
        rot = mat2(cos(rotAngle), -sin(rotAngle), sin(rotAngle), cos(rotAngle));
        tapRange = 1;
    }

    for (int x = -tapRange; x <= tapRange; x++) {
        for (int y = -tapRange; y <= tapRange; y++) {
            vec2 off = rot * (vec2(x, y) * stepSize);
            vec2 nUV = uv + off * texelSize;
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            vec3  nColor = textureLod(giTex, nUV, 0.0).rgb;
            vec4  nm     = textureLod(momentTex, nUV, 0.0);
            float nLuma  = luma(nColor);
            float nDepthRaw = textureLod(depthTex, nUV, 0.0).r;
            float nDepth = getDepth(nDepthRaw);
            vec3  nN     = normalize(textureLod(normalTex, nUV, 0.0).rgb * 2.0 - 1.0);

            float hw = atrousW(abs(x)) * atrousW(abs(y));
            float w;
            if (x == 0 && y == 0) {
                w = hw;
            } else {
                // plane awareness via screen-space depth gradient (see svgfAtrous)
                float expectedD = centerDepth + dot(depthGrad, off);
                float wz = exp(-abs(nDepth - expectedD) * invSigmaZ);
                float wn = pow(max(dot(nN, centerN), 0.0), sigmaN);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);

                w = hw * wz * wn * wl;

                #ifdef SVGF_WORLD_RADIUS
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

    mat2 rot = mat2(1.0, 0.0, 0.0, 1.0);
    int tapRange = 2;

    if (stepSize > 2.0) {
        float rotAngle = getJitterRotation(uv, frameCounter);
        rot = mat2(cos(rotAngle), -sin(rotAngle), sin(rotAngle), cos(rotAngle));
        tapRange = 1;
    }

    for (int x = -tapRange; x <= tapRange; x++) {
        for (int y = -tapRange; y <= tapRange; y++) {
            vec2 off = rot * (vec2(x, y) * stepSize);
            vec2 nUV = uv + off * texelSize;
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            vec4  n      = textureLod(src, nUV, 0.0);
            float nLuma  = luma(n.rgb);
            float nDepthRaw = textureLod(depthTex, nUV, 0.0).r;
            float nDepth = getDepth(nDepthRaw);
            vec3  nN     = normalize(textureLod(normalTex, nUV, 0.0).rgb * 2.0 - 1.0);

            float hw = atrousW(abs(x)) * atrousW(abs(y));
            float w;
            if (x == 0 && y == 0) {
                w = hw;
            } else {
                // Plane awareness comes from the screen-space depth gradient
                // (expectedD) — equivalent to the old per-tap inverse-projection
                // plane test but without two mat4 mults per tap.
                float expectedD = centerDepth + dot(depthGrad, off);
                float wz = exp(-abs(nDepth - expectedD) * invSigmaZ);
                float wn = pow(max(dot(nN, centerN), 0.0), sigmaN);
                float wl = exp(-abs(cLuma - nLuma) * invSigmaL);

                w = hw * wz * wn * wl;

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
