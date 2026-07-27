// sc2_sky_sh : project the sky into second-order spherical harmonics.
//
// Runs once per frame, one work group, 512 samples total. The cost is a few
// microseconds; the point is to move four texelFetches per MISSED RAY out of
// both the final gather and the surface cache bounce loop and replace them with
// nine coefficients. See lib/pt/skySH.glsl for why that is also a noise win.
//
// STALENESS. shadowcomp runs before prepare, so colortex12 (the atmosphere LUT)
// is one frame old here -- the same condition sc1_surface_direct already works
// under, and documented alongside it. The LUT changes over minutes of world
// time, so a frame of lag is not observable. Note the consequence for ORDER
// though: sc1 runs before this pass, so the surface cache reads the PREVIOUS
// frame's coefficients while the gather (deferred) reads this frame's. Both are
// fine for the same reason.
//
// NO implicit-LOD sampling here. texture() has no derivatives in compute and
// drivers return 0, which is what silently zeroed the shadow lookup once
// already. Verified before writing this: sampleSky_fast reaches the LUT through
// _bilinearLUT, which is built on texelFetch, so this path is compute-safe.

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/pt/skySH.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/fragment/sky.glsl"

#define SKY_SH_THREADS 32
#define SKY_SH_PER_THREAD 16
#define SKY_SH_SAMPLES (SKY_SH_THREADS * SKY_SH_PER_THREAD)

// workGroups MUST be literal integers -- Iris parses this out of the source text
// and does not evaluate GLSL. One group is all this needs.
layout(local_size_x = SKY_SH_THREADS) in;
const ivec3 workGroups = ivec3(1, 1, 1);

shared vec3 sPartial[SKY_SH_THREADS][9];

// Fibonacci sphere: near-uniform coverage with no clustering at the poles, and
// no random numbers, so the coefficients do not shimmer frame to frame.
vec3 fibonacciDir(int i, int n) {
    float k     = float(i) + 0.5;
    float cosT  = 1.0 - 2.0 * k / float(n);
    float sinT  = sqrt(max(0.0, 1.0 - cosT * cosT));
    float phi   = 3.14159265 * (1.0 + sqrt(5.0)) * k;
    return vec3(cos(phi) * sinT, cosT, sin(phi) * sinT);
}

void main() {
    int tid = int(gl_LocalInvocationID.x);

    vec3 acc[9];
    for (int k = 0; k < 9; ++k) acc[k] = vec3(0.0);

    float eyeAlt = ptEyeAltitude();

    // Solid angle per sample. Uniform directions, so every sample carries the
    // same weight and the projection is a plain weighted sum.
    float w = 4.0 * 3.14159265 / float(SKY_SH_SAMPLES);

    for (int s = 0; s < SKY_SH_PER_THREAD; ++s) {
        int  i   = tid * SKY_SH_PER_THREAD + s;
        vec3 dir = fibonacciDir(i, SKY_SH_SAMPLES);

        // sampleSky_fast, never sampleSky: the latter carries the sun and moon
        // discs (x1000 and x100). Projecting those into nine coefficients would
        // smear a point light across the entire sphere and wash out every
        // indirect ray in the scene.
        vec3 radiance = sampleSky_fast(dir, eyeAlt);

        float Y[9];
        skySHBasis(dir, Y);
        for (int k = 0; k < 9; ++k) acc[k] += radiance * (Y[k] * w);
    }

    for (int k = 0; k < 9; ++k) sPartial[tid][k] = acc[k];

    barrier();
    memoryBarrierShared();

    // 32 x 9 adds on one thread, once per frame. Not worth a tree reduction.
    if (tid == 0) {
        for (int k = 0; k < 9; ++k) {
            vec3 sum = vec3(0.0);
            for (int t = 0; t < SKY_SH_THREADS; ++t) sum += sPartial[t][k];
            skySH.L[k] = vec4(sum, 0.0);
        }
    }
}
