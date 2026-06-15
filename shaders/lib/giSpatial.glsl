#ifndef GI_SPATIAL_GLSL
#define GI_SPATIAL_GLSL

// Shared history-guided a-trous wavelet pass for the per-pixel GI denoiser.
// Each deferred pass (d2..d5) sets INPUT_TEX + STEP_SIZE then calls giSpatialFilter().
// Keeping the body in one place guarantees all four passes stay in sync: the
// render-scale-correct view reconstruction, the history-derived edge-stop, and
// the history-adaptive geometry weights are identical at every wavelet level.
// The edge-stop tolerance is derived from history length (no per-pass variance loop)
// and the kernel half-width is GID_ATROUS_RADIUS (1 = 3x3 fast, 2 = 5x5).
//
// Requires (from the including program): texCoord (frag in), getTaaJitter(),
// and the INPUT_TEX / STEP_SIZE macros.

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

    // --- History-driven luminance edge-stop --------------------------------------
    // The old code estimated a per-pass spatial 3x3 variance (9 extra taps/pass) just
    // to set this tolerance. iterationRP derives the same thing straight from history
    // length, which is ~9 taps/pass cheaper: a low-history (noisy / freshly-disoccluded)
    // pixel filters LOOSE so the wavelet blurs its 1-spp noise wide (this is what
    // GID_DISOCC_BOOST now scales), and a converged pixel filters TIGHT to keep detail.
    // The per-neighbour difference is still normalised by a stable local brightness with
    // an absolute floor (GID_LUMA_FLOOR) — that scale-invariant relative metric is what
    // keeps dark interiors from "boiling".
    float sigmaRel  = float(GID_SIGMA_L) * sqrt(float(GID_DISOCC_BOOST) / max(histLen, 1.0)) * 0.1 + 0.08;
    float lumaScale = max(centerLuma, float(GID_LUMA_FLOOR));

    // --- History-adaptive geometry tightness ------------------------------------
    // Loose for fresh pixels (gather aggressively to hide 1-spp), sharp once converged.
    float normalExp  = mix(GID_NORMAL_EXP_MIN * 0.5, 32.0, conv);
    float depthScale = mix(5.0, max(30.0 / -viewPos.z, 5.0), conv) * GID_DEPTH_STRICTNESS;

    // Surface-aligned anisotropy: stretch the kernel along grazing surfaces.
    float VdotN = max(dot(centerNormal, -viewDir), 0.0);
    vec2 normalTransDir = normalize(centerNormal.xy + 1e-10);
    float stretch = clamp(1.0 - VdotN, 0.0, 1.0);

    const float kernel[3] = float[3](1.0, 2.0 / 3.0, 1.0 / 6.0);
    const int R = GID_ATROUS_RADIUS; // 1 = 3x3 (8 taps), 2 = 5x5 (24 taps)

    vec3 sumCol = centerData.rgb;
    float sumW = 1.0;

    for (int y = -R; y <= R; y++) {
        for (int x = -R; x <= R; x++) {
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
