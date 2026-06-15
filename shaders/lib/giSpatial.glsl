#ifndef GI_SPATIAL_GLSL
#define GI_SPATIAL_GLSL

// Shared variance-guided a-trous wavelet pass for the per-pixel GI denoiser.
// Each deferred pass (d2..d5) sets INPUT_TEX + STEP_SIZE then calls giSpatialFilter().
// Keeping the body in one place guarantees all four passes stay in sync: the
// render-scale-correct view reconstruction, the per-pixel variance estimate, and
// the history-adaptive edge weights are identical at every wavelet level.
//
// Requires (from the including program): texCoord (frag in), getTaaJitter(),
// getDepth(), and the INPUT_TEX / STEP_SIZE macros.

#ifndef TEMPORAL_MAX_FRAMES
#define TEMPORAL_MAX_FRAMES float(GID_TEMPORAL_MAX_FRAMES)
#endif

float giLuma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// View-space position from a render-scale-correct sample coord. sampleCenter is in
// the SCALED [0,renderScale] region, so divide back out before mapping to NDC. (The
// old d3/d4/d5 skipped the /renderScale, corrupting their depth weights below 1.0x.)
vec3 giViewPos(vec2 sampleCenter, float depth) {
    vec2 ndcXY = sampleCenter / renderScale * 2.0 - 1.0;
    vec4 p = gbufferProjectionInverse * vec4(ndcXY, depth * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

vec4 giSpatialFilter() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));
    vec2 unjitteredCoord = texCoord * renderScale;

    float depth0 = texture(depthtex0, sampleCenter).r;
    if (depth0 >= 1.0) return vec4(0.0);

    vec3 centerNormal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
    vec4 centerData = texture(INPUT_TEX, unjitteredCoord);
    if (length(centerNormal) <= 0.001) return centerData;

    vec3 viewPos = giViewPos(sampleCenter, depth0);
    vec3 viewDir = normalize(viewPos);

    float centerLuma = giLuma(centerData.rgb);
    float histLen = min(centerData.a, TEMPORAL_MAX_FRAMES);
    float conv    = clamp(histLen / TEMPORAL_MAX_FRAMES, 0.0, 1.0);

    // --- Per-pixel luminance variance (3x3 at this wavelet's stride) -------------
    // Estimated spatially each pass, then inflated for low-history pixels so freshly
    // disoccluded regions blur wide (GID_DISOCC_BOOST) and converged regions stay
    // tight. sqrt(variance) -> a luminance scale that drives the edge-stop below.
    float m1 = 0.0, m2 = 0.0, mW = 0.0;
    float centerDepthLin = getDepth(depth0);
    for (int vy = -1; vy <= 1; vy++) {
        for (int vx = -1; vx <= 1; vx++) {
            vec2 vOff = vec2(vx, vy) * STEP_SIZE * texelSize * renderScale;
            float vDepth = texture(depthtex0, sampleCenter + vOff).r;
            if (abs(centerDepthLin - getDepth(vDepth)) < 0.1 * max(centerDepthLin, 1.0)) {
                float vL = giLuma(texture(INPUT_TEX, unjitteredCoord + vOff).rgb);
                m1 += vL; m2 += vL * vL; mW += 1.0;
            }
        }
    }
    float variance = 0.0;
    if (mW > 0.5) { m1 /= mW; m2 /= mW; variance = max(m2 - m1 * m1, 0.0); }
    variance += (m1 * m1 + 1e-4) * (float(GID_DISOCC_BOOST) / max(histLen, 1.0));

    // Scale-invariant (perceptual) luma edge-stop. Normalising BOTH the variance
    // and the per-neighbour difference by a stable local brightness keeps the blur
    // strength consistent from bright surfaces down to dark interiors. Using the
    // neighbourhood MEAN (steadier than per-frame variance) with an absolute floor
    // (GID_LUMA_FLOOR) is what stops the dark-area "boiling": the old absolute
    // metric let sigmaL collapse in shadow so the wavelet rejected every neighbour
    // and 1-spp noise survived. relTol below is a hard minimum tolerance (in
    // fraction-of-brightness) so faintly-noisy flat regions still blur.
    float lumaScale  = max(max(m1, centerLuma), float(GID_LUMA_FLOOR));
    float relStdDev  = sqrt(variance) / lumaScale;
    float sigmaRel   = relStdDev * float(GID_SIGMA_L) + 0.1;

    // --- History-adaptive geometry tightness ------------------------------------
    // Loose for fresh pixels (gather aggressively to hide 1-spp), sharp once converged.
    float normalExp  = mix(GID_NORMAL_EXP_MIN * 0.5, 32.0, conv);
    float depthScale = mix(5.0, max(30.0 / -viewPos.z, 5.0), conv) * GID_DEPTH_STRICTNESS;

    // Surface-aligned anisotropy: stretch the kernel along grazing surfaces.
    float VdotN = max(dot(centerNormal, -viewDir), 0.0);
    vec2 normalTransDir = normalize(centerNormal.xy + 1e-10);
    float stretch = clamp(1.0 - VdotN, 0.0, 1.0);

    const float kernel[3] = float[3](1.0, 2.0 / 3.0, 1.0 / 6.0);

    vec3 sumCol = centerData.rgb;
    float sumW = 1.0;

    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            if (x == 0 && y == 0) continue;

            vec2 baseOffset = vec2(x, y) * STEP_SIZE;
            float normalTransWeight = -dot(baseOffset, normalTransDir) * stretch;
            baseOffset += normalTransDir * normalTransWeight;

            vec2 offset = baseOffset * texelSize;
            vec2 sampleCoord = sampleCenter + offset;
            vec2 sampleUnjittered = unjitteredCoord + offset;

            if (any(lessThan(sampleCoord, vec2(0.0))) || any(greaterThanEqual(sampleCoord, vec2(renderScale)))) continue;

            float sampleDepth0 = texture(depthtex0, sampleCoord).r;
            if (sampleDepth0 >= 1.0) continue;
            vec3 sampleNormal = normalize(texture(colortex1, sampleCoord).rgb * 2.0 - 1.0);

            float wNormal = pow(max(dot(centerNormal, sampleNormal), 0.0), normalExp);

            vec3 sampleViewPos = giViewPos(sampleCoord, sampleDepth0);
            float depthGradient = dot(sampleViewPos - viewPos, centerNormal);
            float wDepth = exp(-abs(depthGradient) * depthScale);

            vec4 sampleData = texture(INPUT_TEX, sampleUnjittered);
            float relDiff = abs(centerLuma - giLuma(sampleData.rgb)) / lumaScale;
            float wLuma = exp(-relDiff / sigmaRel);

            float w = kernel[abs(x)] * kernel[abs(y)] * wNormal * wDepth * wLuma;

            sumCol += sampleData.rgb * w;
            sumW += w;
        }
    }

    vec4 spatialOut;
    spatialOut.rgb = sumCol / max(sumW, 1e-5);
    spatialOut.a = centerData.a;

    if (any(isnan(spatialOut)) || any(isinf(spatialOut))) {
        spatialOut = vec4(0.0, 0.0, 0.0, 1.0);
    }
    return spatialOut;
}

#endif
