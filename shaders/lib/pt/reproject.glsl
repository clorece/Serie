#ifndef PT_REPROJECT_GLSL
#define PT_REPROJECT_GLSL

// Temporal reuse primitives for the tracing stack.
// ---------------------------------------------------------------------------
// Harvested from the pre-Lumen SVGF denoiser (lib/pt/denoise.glsl,
// lib/pt/historyfix.glsl) so they survive the deletion of that chain. The
// Lumen final gather still needs a history clamp, a TAA-phase-locked kernel
// rotation, and a disocclusion fill even though the a-trous chain itself is
// gone -- screen probes converge, but freshly disoccluded pixels have no probe
// history to converge from.

#ifndef FRAME_COUNTER_DECLARE
#define FRAME_COUNTER_DECLARE
#endif

// texelSize, octDecodeNormal, far
#include "/lib/util/common.glsl"
#include "/lib/options.glsl"
// luma
#include "/lib/pt/sampling.glsl"

// ---- History colour clamp --------------------------------------------------

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

// history, m1, m2: m1/m2 are the YCoCg first/second moments of the local
// neighbourhood; history is in RGB.
vec3 clipHistoryMoments(vec3 history, vec3 m1, vec3 m2) {
    vec3 std = sqrt(max(m2 - m1 * m1, 0.0));
    // m1/m2/std are in YCoCg space: only Y (luma) is non-negative, so the
    // "cap std at 2x the mean" anti-overshoot heuristic is valid for Y alone.
    // The Co/Cg chroma means are SIGNED (warm colors have Cg < 0); capping their
    // std against m1*2 gives a negative std, which inverts the clamp window below
    // and forces chroma to the wrong side -> warm emitters (torch/lava) shift to
    // purple and white emitters skew blue as the history converges.
    std.x = min(std.x, m1.x * 2.0);

    // Box clamp history to [mean - k*std, mean + k*std]
    vec3 h = RGBtoYCoCg(history);
    return YCoCgtoRGB(clamp(h, m1 - std * 1.5, m1 + std * 1.5));
}

// ---- Variance floor --------------------------------------------------------

float varFromMoments(float m1, float m2) {
    return max(m2 - m1 * m1, 0.0);
}

// Minimum relative-luminance variance, boosted in the dark where the eye is
// most sensitive to residual/checker noise.
float svgfVarianceFloor(float centerLuma) {
    float lowLightBoost = mix(3.0, 1.0, smoothstep(0.02, 0.18, abs(centerLuma)));
    float sigma = max(abs(centerLuma) * GI_MIN_LUMA_SIGMA * lowLightBoost, 0.006);
    return sigma * sigma;
}

// ---- Kernel rotation -------------------------------------------------------

// Per-pixel rotation angle whose temporal component is locked to the 8-frame
// TAA jitter period, so successive frames present decorrelated kernel
// orientations that TAA then averages coherently.
float getJitterRotation(vec2 uv, int frame) {
    vec2 p = uv * vec2(viewWidth, viewHeight);
    float perPixel = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) * 6.2831853;
    float taaPhase = float(frame % 8) * (6.2831853 / 8.0); // locked to the TAA jitter period
    return perPixel + taaPhase;
}

// ---- Disocclusion fill -----------------------------------------------------

// Pixels that never build temporal history -- silhouette edges, convex corners,
// freshly disoccluded regions -- sit at histLen ~= 1 and therefore display the
// raw low-spp radiance, which reads as edge fireflies.
//
// This is a spatial PREFILTER in the ReLAX/ReBLUR "history-fix" family: for a
// low-history pixel we pool the already-accumulated GI of geometrically-similar
// neighbours, biasing toward higher-confidence (longer-history) taps and
// damping bright outliers with a Karis luminance weight, then blend the pooled
// estimate in proportional to how little history the pixel has. The
// reconstructed value is written back to the history so downstream temporal
// stages inherit it.
//
// Original implementation; the technique is the published disocclusion-fix idea
// (NVIDIA ReLAX/ReBLUR), not copied code.

// 16-tap Vogel disk (unit radius), rotated per pixel/frame so residual structure
// decorrelates and the temporal stage mops it up.
const vec2 HF_DISK[16] = vec2[16](
    vec2( 0.17678,  0.00000), vec2(-0.22584,  0.20678),
    vec2( 0.03482, -0.39374), vec2( 0.28473,  0.37107),
    vec2(-0.52130, -0.09744), vec2( 0.49330, -0.31693),
    vec2(-0.16482,  0.61570), vec2(-0.31351, -0.60866),
    vec2( 0.68458,  0.25019), vec2(-0.71252,  0.29343),
    vec2( 0.34494, -0.73299), vec2( 0.25494,  0.80854),
    vec2(-0.76627, -0.44056), vec2( 0.89859, -0.19052),
    vec2(-0.54639,  0.77955), vec2(-0.12784, -0.97591)
);

// pixCenter / pixMax are in BUFFER pixels (already inside the renderScale region).
// giHist:  rgb = accumulated GI, a = history length.
// gbufND:  xy  = oct-encoded world normal, z = linear depth.
// (Both were hardcoded to colortex8 / colortex15 in the ReSTIR-era denoiser.
// They are parameters now because deleting that chain frees ct8 -- the GI
// history will live somewhere else in the Lumen buffer layout.)
// Returns the reconstructed GI; outFix reports the blend amount (debug/tuning).
vec3 historyFixGI(
    sampler2D giHist, sampler2D gbufND,
    ivec2 pixCenter, ivec2 pixMax,
    vec3 accumGI, float histLen,
    vec3 nrm, float linDepth,
    out float outFix
) {
    // 1 when the pixel has little/no history, fading to 0 once it has converged
    // (>= HISTORYFIX_MAX_FRAMES) so settled detail is left completely untouched.
    float fixAmount = 1.0 - smoothstep(float(HISTORYFIX_MIN_FRAMES),
                                       float(HISTORYFIX_MAX_FRAMES), histLen);
    outFix = fixAmount;
    if (fixAmount < 0.02) return accumGI; // cheap path for the converged majority

    // fresher pixels reach further to find clean, settled neighbours
    float radius = mix(2.0, float(HISTORYFIX_RADIUS), fixAmount);
    float ang = getJitterRotation(vec2(pixCenter) * texelSize, frameCounter);
    mat2 rot = mat2(cos(ang), -sin(ang), sin(ang), cos(ang));

    float depthTol = max(linDepth, 1.0) * HISTORYFIX_DEPTH_TOL;

    // seed with a small self-weight (Karis) so a lone valid pixel keeps itself
    float wSelf = (1.0 / (1.0 + luma(accumGI))) * 0.5;
    vec3  sum  = accumGI * wSelf;
    float wsum = wSelf;

    for (int i = 0; i < HISTORYFIX_SAMPLES; i++) {
        vec2  off = rot * (HF_DISK[i] * radius);
        ivec2 q   = clamp(pixCenter + ivec2(round(off)), ivec2(0), pixMax);

        vec4  nd     = texelFetch(gbufND, q, 0);
        float nDepth = nd.z;
        if (nDepth >= far * 0.999) continue; // skip sky taps

        vec3  nN = octDecodeNormal(nd.xy);
        vec4  nH = texelFetch(giHist, q, 0);

        float wN = pow(max(dot(nrm, nN), 0.0), float(HISTORYFIX_SIGMA_N)); // same surface
        float wZ = exp(-abs(nDepth - linDepth) / depthTol);                // same plane
        float wH = nH.a + 1.0;                  // borrow from converged neighbours
        float wF = 1.0 / (1.0 + luma(nH.rgb));  // Karis: damp bright outliers
        float w  = wN * wZ * wH * wF;

        sum  += nH.rgb * w;
        wsum += w;
    }

    if (wsum < 1e-5) return accumGI;
    vec3 pooled = sum / wsum;
    return mix(accumGI, pooled, fixAmount);
}

#endif
