#ifndef PT_ATROUS_GLSL
#define PT_ATROUS_GLSL

// ---------------------------------------------------------------------------
// Edge-stopping a-trous wavelet filter for the GI buffer, ReLAX-flavoured.
//
// This is deliberately NOT the SVGF chain that Phase 1 deleted. That one existed
// to rescue a 1-spp ReSTIR signal and needed five passes plus per-pixel variance
// estimation and moment accumulation. Here the surface cache is already
// temporally converged before the gather even runs, so what reaches this filter
// is a mild residual -- a couple of rays of sampling noise and the short-range
// AO term, both already smoothed by 32 frames of accumulation. A short stride
// ladder is enough, and each pass we do NOT run is a full-resolution RGBA16F
// read and write we do not pay for.
//
// One 3x3 tap set per pass (9 taps), not SVGF's 5x5 (25). With strides doubling
// per pass the support still reaches far: four passes at 1/2/4/8 cover a 31x31
// footprint for 36 taps, where a single 31x31 gather would be 961.
//
// Edge stopping uses world normal and linear depth from colortex15, plus a luma
// term whose tolerance widens on pixels with little temporal history. That last
// part stands in for SVGF's variance estimate: rather than accumulate moments in
// another buffer, use history length as the confidence proxy the pack already
// has. A fresh pixel is noisy and should blur freely; a converged one is
// trustworthy and should keep its detail.
// ---------------------------------------------------------------------------

#include "/lib/options.glsl"

// 3x3 B3-spline row weights; the 2D kernel is their outer product.
const float ATROUS_W[3] = float[3](0.25, 0.5, 0.25);

// gi:  .rgb indirect, .a history length
// key: .xy oct world normal, .z linear depth  (colortex15)
vec4 atrousGI(sampler2D gi, sampler2D key, ivec2 pix, ivec2 pixMax, int stride) {
    vec4 c = texelFetch(gi, pix, 0);

    vec4  k0 = texelFetch(key, pix, 0);
    vec3  n0 = octDecodeNormal(k0.xy);
    float z0 = k0.z;

    // Sky and anything without a valid key passes straight through: there is no
    // indirect light there and blurring across the silhouette would drag GI onto
    // the sky.
    if (z0 >= far * 0.999) return c;

    float histLen = c.a;

    // Depth tolerance scales with distance so a fixed world-space slope reads the
    // same near and far.
    float zTol = max(z0, 1.0) * GI_DN_SIGMA_Z;

    // Luma tolerance: loose where there is no history to trust, tightening as the
    // pixel converges. This is the variance estimate's job in SVGF, done with a
    // value the pack already carries instead of another buffer.
    float lumaTol = GI_DN_SIGMA_L * (1.0 + 4.0 / sqrt(max(histLen, 1.0)));
    float l0 = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));

    vec3  sum  = vec3(0.0);
    float wsum = 0.0;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 q = clamp(pix + ivec2(dx, dy) * stride, ivec2(0), pixMax);

            vec4  kq = texelFetch(key, q, 0);
            float zq = kq.z;
            if (zq >= far * 0.999) continue;      // never pull from sky

            vec4 cq = texelFetch(gi, q, 0);

            vec3  nq = octDecodeNormal(kq.xy);
            float wN = pow(max(dot(n0, nq), 0.0), GI_DN_SIGMA_N);
            float wZ = exp(-abs(zq - z0) / zTol);
            float lq = dot(cq.rgb, vec3(0.2126, 0.7152, 0.0722));
            float wL = exp(-abs(lq - l0) / lumaTol);

            float w = ATROUS_W[dx + 1] * ATROUS_W[dy + 1] * wN * wZ * wL;

            sum  += cq.rgb * w;
            wsum += w;
        }
    }

    // wsum always includes the centre tap at full edge-stopping weight, so it
    // cannot be zero; the guard is for a NaN sneaking in from upstream.
    return (wsum > 1e-6) ? vec4(sum / wsum, histLen) : c;
}

#endif
