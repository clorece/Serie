// d9_vl : atmospheric volumetric light. Per-pixel shadowmap-aware raymarch
// that replaces d8's flat aerial perspective for terrain pixels when
// VOLUMETRIC_LIGHT is enabled. Sky pixels (depth==1) are passed through —
// d8 already wrote the sky color.
//
// Integration is identical to computeAerialPerspective() except sun in-scatter
// is multiplied by a single shadowmap tap per step. Moon stays unshadowed
// (cheap, MC nights don't need crepuscular rays through clouds).

/* RENDERTARGETS: 0 */

#ifdef VERTEX

out vec2 texCoord;
out vec3 sunVector;
out vec3 moonVector;
out vec3 lightVector;
out vec3 upVector;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    #include "/lib/vectors.glsl"
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/util/dither.glsl"

in vec2 texCoord;
in vec3 sunVector;
in vec3 moonVector;
in vec3 lightVector;
in vec3 upVector;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/fragment/atmosphereLUT.glsl"


void main() {
#ifndef VOLUMETRIC_LIGHT
    gl_FragData[0] = vec4(texture(colortex0, texCoord).rgb, 1.0);
    return;
#else
    vec3 sceneColor = texture(colortex0, texCoord).rgb;

    // Unjitter for accurate depth + world-position derivation.
    vec2 unjit = texCoord;
    #ifdef TAA
    unjit -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif

    float depth = texture(depthtex0, unjit).r;
    if (depth >= 1.0) {
        // Sky pixel — d8's sampleSky() already handled it.
        gl_FragData[0] = vec4(sceneColor, 1.0);
        return;
    }

    clipSpace = vec3(unjit, depth) * 2.0 - 1.0;
    vec3  fragPosition = getFragPosition().xyz;
    vec3  viewDir      = normalize(fragPosition);
    vec3  worldDir     = mat3(gbufferModelViewInverse) * viewDir;
    vec3  worldSunDir  = mat3(gbufferModelViewInverse) * sunVector;

    // Sun-below-horizon early-out: at night there are no godrays to integrate,
    // and the dim moon contribution isn't worth 16 shadow taps per pixel. Pass
    // the scene through. (Threshold = a few degrees below horizon to avoid a
    // hard cutoff at the terminator.)
    if (worldSunDir.y < -0.05) {
        gl_FragData[0] = vec4(sceneColor, 1.0);
        return;
    }

    float dist   = length(fragPosition);
    float eyeAlt = cameraPosition.y - 64.0;

    int   N       = VL_STEPS;
    float stepLen = dist / float(N);
    float dither  = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    float r0  = PLANET_RADIUS + max(eyeAlt, 0.0);
    vec3  posCenter = vec3(0.0, r0, 0.0);

    vec2 phaseSun = GetPhase(dot(worldDir, worldSunDir), MIE_G);

    vec3 trans   = vec3(1.0);
    vec3 scatter = vec3(0.0);

    float sunFade = smoothstep(-0.2, 0.05, worldSunDir.y);

    for (int i = 0; i < N; ++i) {
        float t = (float(i) + dither) * stepLen;

        // Shadow sample at the world-relative sample position.
        vec4 shadowPos = toShadowSpace(vec4(worldDir * t, 1.0));
        float shadow = 1.0;
        if (shadowPos.x >= 0.0 && shadowPos.x <= 1.0 &&
            shadowPos.y >= 0.0 && shadowPos.y <= 1.0)
        {
            float receiverDepth = shadowPos.z - 0.0001;
            shadow = step(receiverDepth, texture(shadowtex0, shadowPos.xy).r);
        }

        // Atmospheric integration (sun only — moon contribution dropped).
        vec3  p_t      = posCenter + worldDir * t;
        float altitude = length(p_t);
        vec3  density  = GetAtmosphereDensity(altitude);

        vec3 sigma_s_r = COEFF_RAYLEIGH * density.x;
        vec3 sigma_s_m = COEFF_MIE * density.y;
        vec3 sigma_s   = sigma_s_r + sigma_s_m;
        vec3 sigma_e   = sigma_s + COEFF_OZONE * density.z;

        float mu_s = dot(normalize(p_t), worldSunDir);
        // Single-tap T-LUT (1 fetch vs 4 for bilinear — quantization is
        // averaged across the N integration steps and invisible).
        vec3  sunT = sampleTransmittanceLUT_fast(mu_s, altitude);

        vec3  psi_ms_sun = sampleMultiScatterLUT_fast(mu_s, altitude);

        const float phaseIsotropic = 1.0 / (4.0 * pi);
        vec3 phaseScatterSun = sigma_s_r * phaseSun.x + sigma_s_m * phaseSun.y;
        vec3 inscatter = (sunT * phaseScatterSun + psi_ms_sun * sigma_s * (phaseIsotropic * sunFade)) * SUN_COLOR_BASE * shadow;

        vec3 stepT = exp(-sigma_e * stepLen);
        vec3 inscatterStep = trans * inscatter * (1.0 - stepT) / max(sigma_e, vec3(1e-7));
        scatter += inscatterStep;
        trans   *= stepT;
    }

    // Match SkyView LUT tone space so VL scatter blends with sky pixels.
    scatter = pow(max(scatter, 0.0), vec3(1.0 / 1.35));

    vec3 finalColor = sceneColor * trans + scatter * VL_INTENSITY;
    gl_FragData[0] = vec4(finalColor, 1.0);
#endif
}

#endif
