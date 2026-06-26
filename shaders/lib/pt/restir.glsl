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
    float wSum;         // running sum of resampling weights
    float M;            // sample count / confidence
    float W;            // resolved unbiased contribution weight
};

Reservoir newReservoir() {
    Reservoir r;
    r.radiance     = vec3(0.0);
    r.samplePos    = vec3(0.0);
    r.sampleNormal = vec3(0.0, 1.0, 0.0);
    r.wSum = 0.0;
    r.M    = 0.0;
    r.W    = 0.0;
    return r;
}

void updateReservoir(inout Reservoir r, vec3 radiance, vec3 samplePos, vec3 sampleNormal, float weight, inout uint seed) {
    r.wSum += weight;
    r.M    += 1.0;
    if (randFloat(seed) * r.wSum < weight) {
        r.radiance     = radiance;
        r.samplePos    = samplePos;
        r.sampleNormal = sampleNormal;
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
    r.wSum         = 0.0;
    return r;
}

#endif
