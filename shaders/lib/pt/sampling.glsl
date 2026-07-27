#ifndef PT_SAMPLING_GLSL
#define PT_SAMPLING_GLSL

// Sampling + BRDF primitives for the tracing stack.
// ---------------------------------------------------------------------------
// Harvested from the pre-Lumen lighting layers (ReSTIR / AO / SSR) so they
// survive the deletion of those passes. Geometry-agnostic: nothing here knows
// about screen space, the voxel cascade, or any particular colortex.

// PI
#include "/lib/options.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

// ---- Tangent frames + cosine hemisphere ------------------------------------

#ifndef PT_TBN_FN
#define PT_TBN_FN
// World-up-aligned tangent frame. The discontinuity sits at near-vertical
// normals (n.y ~ +/-1) rather than at n.z == 0, which is what makes it safe on
// X-facing walls -- see the note on stbnCosineHemisphere below.
void buildTBN(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

vec3 cosHemisphereDir(vec3 n, float r1, float r2) {
    float phi      = 2.0 * PI * r1;
    float sinTheta = sqrt(r2);        // cosine-weighted: pdf = cos(theta)/pi
    float cosTheta = sqrt(1.0 - r2);
    vec3 t, b;
    buildTBN(n, t, b);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + n * cosTheta);
}
#endif

// ---- Spatiotemporal blue noise ---------------------------------------------

#ifdef GI_BLUE_NOISE
#ifndef PT_BLUENOISE_DECLARED
#define PT_BLUENOISE_DECLARED
// STBN cosine-hemisphere texture (128x128 spatial tile x 64 temporal frames),
// bound globally via customTexture.blueNoise -> noise/stbn_cosine.dat. Declared
// HERE, not in uniforms.glsl, on purpose: the world0/*.fsh wrappers include
// uniforms.glsl BEFORE the program file pulls in options.glsl, so a
// GI_BLUE_NOISE-gated decl there is reached before the macro exists (and the
// include guard then blocks the re-include). This file is included after
// options.glsl, so the guard is live and the uniform is actually declared.
uniform sampler3D blueNoise;
#endif

// Cosine-weighted hemisphere direction around `normal`, drawn from the NVIDIA
// spatiotemporal blue-noise cosine texture. The texture stores cosine dirs in
// the +Z hemisphere; we rotate into the surface tangent frame via buildTBN.
// Replaces white-noise cosHemisphereDir so low-spp noise is blue
// (denoiser-friendly) rather than full-spectrum -> less boiling.
//
// buildTBN, not the Duff 2017 ONB: that has a sign discontinuity at n.z == 0,
// so on X-facing walls (world-normal z ~ 0, jittered across the seam by PBR
// bump normals) the frame flipped pixel-to-pixel and the cosine STBN mapped
// through it as vertical streaks.
vec3 stbnCosineHemisphere(vec3 normal, ivec2 pixel, int frame) {
    ivec3 c = ivec3(pixel.x & 127, pixel.y & 127, frame & 63);
    vec3 d  = texelFetch(blueNoise, c, 0).xyz * 2.0 - 1.0;
    vec3 t, b;
    buildTBN(normal, t, b);
    return normalize(d.x * t + d.y * b + d.z * normal);
}
#endif

// ---- Specular BRDF ---------------------------------------------------------

#ifndef PT_BRDF_FN
#define PT_BRDF_FN
vec3 fresnelSchlick(float cosTheta, vec3 f0) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    return f0 + (1.0 - f0) * (m * m * m * m * m);
}

// Height-correlated Smith GGX visibility terms.
float smithGGX_v1(float NoV, float alphaSq) {
    return 1.0 / (NoV + sqrt((NoV - NoV * alphaSq) * NoV + alphaSq));
}
float smithGGX_v2(float NoL, float NoV, float alphaSq) {
    float ggxV = NoL * sqrt((NoV - NoV * alphaSq) * NoV + alphaSq);
    float ggxL = NoV * sqrt((NoL - NoL * alphaSq) * NoL + alphaSq);
    return 0.5 / max(ggxV + ggxL, 1e-6);
}

// GGX VNDF importance sampling (zombye 2023). viewDir and the
// returned microfacet normal are in TANGENT space. roughness = alpha.
vec3 sampleGGXVNDF(vec3 viewDir, float alpha, vec2 hash) {
    viewDir = normalize(vec3(alpha * viewDir.xy, viewDir.z));

    const float tau = 6.2831853;
    float phi = tau * hash.x;
    float cosTheta = (1.0 - hash.y) * (1.0 + viewDir.z) - viewDir.z;
    float sinTheta = sqrt(clamp(1.0 - cosTheta * cosTheta, 0.0, 1.0));
    vec3 reflected = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    vec3 halfway = reflected + viewDir;
    return normalize(vec3(alpha * halfway.xy, halfway.z));
}

// Arbitrary orthonormal tangent frame from a normal (columns T, B, N).
// Distinct from buildTBN: +Z-aligned, for the tangent-space VNDF convention.
mat3 tbnFromNormal(vec3 N) {
    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 T = normalize(cross(up, N));
    vec3 B = cross(N, T);
    return mat3(T, B, N);
}
#endif

#endif
