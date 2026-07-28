// dr1_reflect_spatial : spatial denoise + composite for the traced reflections.
//
// Runs after dr0_reflect, which wrote the temporally-accumulated, DEMODULATED
// reflection and its history length to colortex4 and left colortex0 as d7
// composited it.
//
// Two jobs:
//
//   1. A history-driven bilateral blur. Where the reflection history is SHORT
//      (disocclusion, camera motion) the kernel widens to hide the per-frame ray
//      noise; where it has converged the radius collapses to zero and the
//      reflection stays sharp. Edge-stopped by normal and depth. This is the one
//      piece of the old screen-space denoiser that has no equivalent anywhere
//      else in the pack, and it is why the ray count can stay as low as it does.
//
//   2. THE ONLY PLACE REFLECTIONS COMPOSITE. Metals replace the diffuse (the
//      surface IS the albedo-tinted reflection); dielectrics keep their diffuse
//      and ADD a weak untinted Fresnel term. The per-texel Fresnel is computed at
//      full resolution and applied AFTER the blur, so the block texture stays
//      crisp no matter how wide the kernel went.

#ifdef VERTEX

#include "/lib/options.glsl"

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/dither.glsl"

vec3 clipSpace; // for positions.glsl; must precede the include

#include "/lib/util/positions.glsl"
#include "/lib/fragment/pbrCommon.glsl"
#include "/lib/fragment/directSpecular.glsl"

in vec2 texCoord;

void main() {
    /* RENDERTARGETS: 0 */

    vec2 uv    = texCoord;
    vec3 scene = texture(colortex0, uv * renderScale).rgb; // the lit diffuse

    float depth = texture(depthtex0, uv * renderScale).r;
    vec4  mat   = texture(colortex7, uv * renderScale);

    // Must match dr0's cutoff exactly, or a pixel composites against a colortex4
    // value that pass never wrote.
    if (depth >= 1.0 || !pbrIsPBR(mat.a) || pbrSmoothness(mat.a) < REFLECTION_SMOOTHNESS_MIN) {
        gl_FragData[0] = vec4(scene, 1.0);
        return;
    }

    vec4  c4         = texture(colortex4, uv * renderScale);
    vec3  centerRefl = c4.rgb;   // demodulated environment reflection, no tint
    float histLen    = c4.a;

    bool  isMetal    = pbrIsMetal(mat.a);
    float smoothness = pbrSmoothness(mat.a);
    float roughness  = 1.0 - smoothness;

    vec3  N       = normalize(texture(colortex1, uv * renderScale).rgb * 2.0 - 1.0);
    vec3  viewPos = convertScreenSpaceToWorldSpace(uv, depth);
    float NoV     = clamp(dot(N, normalize(-viewPos)), 1e-3, 1.0);

    // Sun visibility from d7_composite (colortex6): the same filtered PCSS +
    // screen-space contact + cloud + sky-access term that gates the diffuse sun.
    // Dims reflections in shadow and in caves, and shadows the glint, so PBR is
    // darkened exactly like the rest of the surface instead of revealing the raw
    // shadow map or shining underground. reflShade keeps a floor, so a shadowed
    // surface still reflects -- just dimmer.
    float sunVis    = clamp(texture(colortex6, uv * renderScale).r, 0.0, 1.0);
    float reflShade = 1.0 - PBR_REFLECT_SHADE * (1.0 - sunVis);

    // Sharp per-texel Fresnel, full resolution, applied after the blur.
    // Metal: F0 = albedo (tints and replaces). Dielectric: F0 = grey (adds).
    vec3 F = (isMetal ? pbrFresnel(NoV, mat.rgb) : pbrFresnel(NoV, vec3(mat.r))) * reflShade;

    // Direct sun/moon glint, added on top -- sharp and deterministic, so it is
    // deliberately outside the denoise. Shadowed by the real sun visibility so it
    // never overpowers the screen-space shadows.
    vec3 specSun = vec3(0.0);
    #if SPECULAR_SUN == 1
        specSun = sunMoonSpecular(N, normalize(-viewPos), viewPos, roughness,
                                  isMetal ? mat.rgb : vec3(mat.r), sunVis)
                * (isMetal ? 1.0 : PBR_DIELECTRIC_SUN);
    #endif

    // Metals: the reflection replaces the diffuse. Non-metals: it adds.
    #define REFL_COMPOSE(env) ((isMetal ? (env) * F : scene + (env) * F) + specSun)

    #ifndef REFLECTION_DENOISE
        gl_FragData[0] = vec4(REFL_COMPOSE(centerRefl), 1.0);
        return;
    #else

    // Radius: full when fresh, ~0 when converged.
    float conv   = clamp(histLen / 8.0, 0.0, 1.0);
    float radius = mix(REFLECTION_SPATIAL_RADIUS, 0.0, conv) * (0.4 + 0.6 * roughness);

    if (radius < 0.6) {
        gl_FragData[0] = vec4(REFL_COMPOSE(centerRefl), 1.0);
        return;
    }

    vec2  viewSize = vec2(viewWidth, viewHeight) * renderScale;
    float rot = interleavedGradientNoise(gl_FragCoord.xy, frameCounter) * 6.2831853;
    mat2  rm  = mat2(cos(rot), -sin(rot), sin(rot), cos(rot));

    vec3  sum  = centerRefl;
    float wsum = 1.0;
    float centerLuma = dot(centerRefl, vec3(0.2126, 0.7152, 0.0722));

    const int TAPS = 12;
    for (int i = 0; i < TAPS; i++) {
        float fi = (float(i) + 0.5) / float(TAPS);
        float r  = sqrt(fi) * radius;      // disk, denser at the centre
        float a  = fi * 6.2831853 * 3.0;   // ~3 turns
        vec2  suv = uv + (rm * vec2(cos(a), sin(a)) * r) / viewSize;
        if (clamp(suv, 0.0, 1.0) != suv) continue;

        if (!pbrIsPBR(texture(colortex7, suv * renderScale).a)) continue; // only blur across PBR
        float sd = texture(depthtex0, suv * renderScale).r;
        if (sd >= 1.0) continue;

        vec3 sRefl = texture(colortex4, suv * renderScale).rgb;
        // Firefly-aware: do not let a much brighter neighbour bleed in and smear
        // into a streak. REFLECTION_SPATIAL_FIREFLY is a compile constant, so 0
        // folds this away entirely.
        if (REFLECTION_SPATIAL_FIREFLY > 0.0 &&
            dot(sRefl, vec3(0.2126, 0.7152, 0.0722)) > centerLuma * REFLECTION_SPATIAL_FIREFLY + 1e-3) continue;

        vec3 sN  = normalize(texture(colortex1, suv * renderScale).rgb * 2.0 - 1.0);
        vec3 sVP = convertScreenSpaceToWorldSpace(suv, sd);

        float wN = pow(max(dot(N, sN), 0.0), 32.0);        // normal edge-stop
        float wD = exp(-abs(sVP.z - viewPos.z) * 4.0);     // depth edge-stop
        float w  = wN * wD;

        sum  += sRefl * w;
        wsum += w;
    }

    gl_FragData[0] = vec4(REFL_COMPOSE(sum / wsum), 1.0);
    #endif
}

#endif
