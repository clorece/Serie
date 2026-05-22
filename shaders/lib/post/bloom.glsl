#ifndef BLOOM_GLSL
#define BLOOM_GLSL

// Soft-knee thresholding function for smooth highlight extraction.
// Extracts colors above 'threshold' with a 'knee' for smooth transition.
// Uses perceptual luminance to ensure colored highlights (not just white) bloom naturally.
vec3 SoftThreshold(vec3 color, float threshold, float knee) {
    const vec3 lumWeight = vec3(0.2126, 0.7152, 0.0722);
    float luma = dot(color, lumWeight);
    
    float rq = clamp(luma - threshold + knee, 0.0, 2.0 * knee);
    rq = rq * rq * 0.25 / max(knee, 0.0001);
    
    float factor = max(luma - threshold, rq) / max(luma, 0.0001);
    
    return color * factor;
}

// Bloom blur weights and offsets (13-tap Gaussian approximation using 7 linear samples)
// Offsets and weights are scaled for a wider spread to achieve a more cinematic look.
const float bloomOffsets[7] = float[](0.0, 1.4117647, 3.2941176, 5.1764705, 7.0588235, 8.9411764, 10.823529);
const float bloomWeights[7] = float[](0.142857, 0.132653, 0.107142, 0.081632, 0.056122, 0.035714, 0.015306);

vec3 BloomBlur(sampler2D tex, vec2 uv, vec2 direction) {
    float spread = 0.75; // Multiplier to increase the physical screen-space spread
    vec3 color = texture(tex, uv).rgb * bloomWeights[0];
    for (int i = 1; i < 7; i++) {
        vec2 offset = direction * bloomOffsets[i] * spread;
        color += texture(tex, uv + offset).rgb * bloomWeights[i];
        color += texture(tex, uv - offset).rgb * bloomWeights[i];
    }
    return color * 7.5;
}

#endif
