#ifndef PBR_COMMON_GLSL
#define PBR_COMMON_GLSL

// Shared integrated-PBR material encoding for colortex7, used by gbuffers_terrain
// (write) and the d7b/d7c reflection passes (read).
//
//   .rgb = reflectance tint:  metal  -> raw albedo (= F0, tints the reflection)
//                             dielec -> F0 as grey (reflection stays untinted)
//   .a   = packed smoothness + metal flag:
//             0            -> non-PBR (no reflection)
//             [0.02, 0.48] -> dielectric, keep diffuse + add Fresnel reflection
//             [0.52, 0.98] -> metal, no diffuse, albedo-tinted reflection

float pbrLightness(vec3 c) {
    return 0.5 * (max(max(c.r, c.g), c.b) + min(min(c.r, c.g), c.b)); // HSL L
}

float pbrPackA(float smoothness, bool isMetal) {
    return (isMetal ? 0.52 : 0.02) + clamp(smoothness, 0.0, 1.0) * 0.46;
}
bool  pbrIsPBR(float a)      { return a > 0.01; }
bool  pbrIsMetal(float a)    { return a > 0.5; }
float pbrSmoothness(float a) { return clamp((a - (a > 0.5 ? 0.52 : 0.02)) / 0.46, 0.0, 1.0); }

vec3 pbrFresnel(float cosTheta, vec3 f0) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    return f0 + (1.0 - f0) * (m * m * m * m * m);
}

#endif
