#ifndef RESTIR_GLSL
#define RESTIR_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/options.glsl"

#include "/lib/util/common.glsl"

#ifndef LUMA_FN
#define LUMA_FN
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
#endif

struct Reservoir {
    vec3  radiance;     // incoming radiance L_i of the held sample
    vec3  samplePos;    // camera-relative world position of the sample hit (for reuse/validation)
    vec3  sampleNormal; // world-space surface normal at the sample hit (for the reconnection Jacobian)
    float wasHit;       // 1.0 if the held sample hit a surface (vs sky/miss) — gates voxel-validity reuse rejection
    float wSum;         // running sum of resampling weights
    float M;            // sample count / confidence
    float W;            // resolved unbiased contribution weight
};

Reservoir newReservoir() {
    Reservoir r;
    r.radiance     = vec3(0.0);
    r.samplePos    = vec3(0.0);
    r.sampleNormal = vec3(0.0, 1.0, 0.0);
    r.wasHit = 0.0;
    r.wSum = 0.0;
    r.M    = 0.0;
    r.W    = 0.0;
    return r;
}

void updateReservoir(inout Reservoir r, vec3 radiance, vec3 samplePos, vec3 sampleNormal, float wasHit, float weight, inout uint seed) {
    r.wSum += weight;
    r.M    += 1.0;
    if (randFloat(seed) * r.wSum < weight) {
        r.radiance     = radiance;
        r.samplePos    = samplePos;
        r.sampleNormal = sampleNormal;
        r.wasHit       = wasHit;
    }
}

void mergeReservoir(inout Reservoir r, Reservoir other, float jacobian, inout uint seed) {
    float weight = luma(other.radiance) * other.W * other.M * jacobian;
    r.wSum += weight;
    r.M    += other.M;
    if (randFloat(seed) * r.wSum < weight) {
        r.radiance     = other.radiance;
        r.samplePos    = other.samplePos;
        r.sampleNormal = other.sampleNormal;
        r.wasHit       = other.wasHit;
    }
}

void finalizeReservoir(inout Reservoir r) {
    float pHat = luma(r.radiance);
    r.W = (pHat > 1e-5 && r.M > 0.0) ? r.wSum / (r.M * pHat) : 0.0;
    r.W = min(r.W, RESTIR_W_MAX);
}

Reservoir readReservoir(sampler2D c10, sampler2D c11, sampler2D c14, vec2 uv) {
    ivec2 texel = ivec2(uv * vec2(viewWidth, viewHeight));
    vec4 a = texelFetch(c10, texel, 0);
    vec4 b = texelFetch(c11, texel, 0);
    vec4 c = texelFetch(c14, texel, 0);
    Reservoir r;
    r.radiance     = a.rgb;
    r.M            = a.a;
    r.samplePos    = b.xyz;
    r.W            = b.a;
    r.sampleNormal = octDecodeNormal(c.xy);
    r.wasHit       = c.z;
    r.wSum         = 0.0;
    return r;
}

#ifdef RESTIR_BLUE_NOISE
// STBN cosine-hemisphere texture (128x128 spatial tile x 64 temporal frames),
// bound globally via customTexture.blueNoise -> noise/stbn_cosine.dat. Declared
// HERE, not in uniforms.glsl, on purpose: the world0/*.fsh wrappers include
// uniforms.glsl BEFORE the program file pulls in options.glsl, so a
// RESTIR_BLUE_NOISE-gated decl there is reached before the macro exists (and the
// include guard then blocks the re-include). restir.glsl is included after
// options.glsl, so the guard is live and the uniform is actually declared.
uniform sampler3D blueNoise;

// World-up-aligned tangent frame — identical to ao.glsl's buildTBN, the frame the
// white-noise cosHemisphereDir path uses. (Previously this was the Duff 2017 ONB,
// which has a sign discontinuity at n.z == 0: on X-facing walls — world-normal
// z ~ 0, jittered across the seam by the PBR bump normals — the frame flipped
// pixel-to-pixel and the cosine STBN mapped through it as vertical streaks. A
// stable world-aligned frame removes that; the discontinuity here is only at
// near-vertical normals (n.y ~ ±1, floors/ceilings), away from wall surfaces.)
void buildONB(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

// Cosine-weighted hemisphere direction around `normal`, drawn from the NVIDIA
// spatiotemporal blue-noise cosine texture (128x128 spatial tile x 64 frames).
// The texture stores cosine dirs in the +Z hemisphere; we rotate into the
// surface tangent frame. Replaces white-noise cosHemisphereDir so the 1-spp GI
// noise is blue (denoiser-friendly) rather than full-spectrum -> less boiling.
vec3 stbnCosineHemisphere(vec3 normal, ivec2 pixel, int frame) {
    ivec3 c = ivec3(pixel.x & 127, pixel.y & 127, frame & 63);
    vec3 d  = texelFetch(blueNoise, c, 0).xyz * 2.0 - 1.0;
    vec3 t, b;
    buildONB(normal, t, b);
    return normalize(d.x * t + d.y * b + d.z * normal);
}
#endif

#endif
