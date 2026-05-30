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
out vec3 lightColor;
out vec3 ambientColor;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
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
in vec3 lightColor;

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

    // Time-of-day volumetric light multipliers (partition of unity)
    float wNoon = smoothstep(0.05, 0.25, worldSunDir.y);
    float wNight = smoothstep(0.05, -0.1, worldSunDir.y);
    float wSunriseSunset = 1.0 - wNoon - wNight;

    float vlMultiplier = wNoon * VL_NOON_STRENGTH + wSunriseSunset * VL_SUN_RISE_SET_STRENGTH + wNight * VL_NIGHT_STRENGTH;

    if (vlMultiplier < 0.001) {
        gl_FragData[0] = vec4(sceneColor, 1.0);
        return;
    }

    vec3  worldLightDir = mat3(gbufferModelViewInverse) * lightVector;

    // Light-below-horizon early-out: when the active light source is well below the horizon,
    // we can skip integration to save performance.
    if (worldLightDir.y < -0.2) {
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

    vec2 phaseLight = GetPhase(dot(worldDir, worldLightDir), MIE_G);

    vec3 trans   = vec3(1.0);
    vec3 scatter = vec3(0.0);

    // Adapt light color, fade factor, and active light source based on day/night
    bool isDay = (worldTime < 12700 || worldTime > 23250);
    float lightFade = isDay ? smoothstep(-0.2, 0.05, worldSunDir.y) : smoothstep(-0.2, 0.05, -worldSunDir.y);
    vec3 lightColorBase = isDay ? SUN_COLOR_BASE : MOON_COLOR_BASE;
    // Blend in some of the dynamic lightColor to give the godrays beautiful time-of-day hues (e.g. sunset gold/amber)
    vec3 dynamicLightColor = lightColor * (isDay ? SUN_ILLUMINANCE : 1.0);
    lightColorBase = mix(lightColorBase, dynamicLightColor, 0.80);

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

        // Atmospheric integration.
        vec3  p_t      = posCenter + worldDir * t;
        float altitude = length(p_t);
        vec3  density  = GetAtmosphereDensity(altitude);

        vec3 sigma_s_r = COEFF_RAYLEIGH * density.x;
        vec3 sigma_s_m = COEFF_MIE * density.y;
        vec3 sigma_s   = sigma_s_r + sigma_s_m;
        vec3 sigma_e   = sigma_s + COEFF_OZONE * density.z;

        float mu_light = dot(normalize(p_t), worldLightDir);
        // Single-tap T-LUT.
        vec3  lightT = sampleTransmittanceLUT_fast(mu_light, altitude);

        vec3  psi_ms_light = sampleMultiScatterLUT_fast(mu_light, altitude);

        const float phaseIsotropic = 1.0 / (4.0 * pi);
        // Use a Mie-dominated scattering for the visible crepuscular rays (god rays)
        // to match dust/fog scattering and perfectly reflect the light source color (eliminating blue god rays).
        vec3 phaseScatterLight = (sigma_s_r * 0.02) * phaseLight.x + sigma_s_m * phaseLight.y;
        vec3 inscatter = (lightT * phaseScatterLight + psi_ms_light * (sigma_s_r * 0.02 + sigma_s_m) * (phaseIsotropic * lightFade)) * lightColorBase * shadow;

        vec3 stepT = exp(-sigma_e * stepLen);
        vec3 inscatterStep = trans * inscatter * (1.0 - stepT) / max(sigma_e, vec3(1e-7));
        scatter += inscatterStep;
        trans   *= stepT;
    }

    // Match SkyView LUT tone space so VL scatter blends with sky pixels.
    scatter = pow(max(scatter, 0.0), vec3(1.0 / 1.35));

    vec3 finalColor = sceneColor * trans + scatter * (VL_INTENSITY * vlMultiplier);
    gl_FragData[0] = vec4(finalColor, 1.0);
#endif
}

#endif
