#include "/lib/fragment/atmosphere.glsl"

vec3 getSunDisc(vec3 rd, vec3 sunDir, vec3 transmittance) {
    float sunHalfAngle = 0.533333 * pi / 180.0 * 0.5;
    float sunCos = cos(sunHalfAngle);
    float sunViewDot = dot(rd, sunDir);
    float sunDisc = smoothstep(sunCos - 0.0001, sunCos + 0.0001, sunViewDot);
    
    vec3 discColor = SUN_COLOR_BASE * transmittance * sunDisc * 50.0;
    return pow(max(discColor, 0.0), vec3(1.0 / 1.2)) * 0.5;
}

vec3 getMoonDisc(vec3 rd, vec3 moonDir, vec3 transmittance) {
    float moonHalfAngle = 0.516667 * pi / 180.0 * 0.5;
    float moonCos = cos(moonHalfAngle);
    float moonViewDot = dot(rd, moonDir);
    float moonDisc = smoothstep(moonCos - 0.0001, moonCos + 0.0001, moonViewDot);
    
    vec3 discColor = MOON_COLOR_BASE * transmittance * moonDisc * 50.0;
    return pow(max(discColor, 0.0), vec3(1.0 / 1.2)) * 0.5;
}

#ifndef SKY_LUT_STEPS
#define SKY_LUT_STEPS 6
#endif

// Disc-free sky for the GI/skylight LUT: atmospheric scattering + ground blend, but NO
// sun/moon discs. The sun is handled separately as direct light, so including the disc in
// the skylight would double-count it (and spawn fireflies in the GI). Mirrors getSky's
// scattering + ground blend exactly so the indirect skylight matches the displayed sky.
vec3 getSkyNoDisc(vec3 rd, vec3 sunDir, vec3 moonDir, float eyeAltitude) {
    vec3 upVec = vec3(0.0, 1.0, 0.0);
    vec3 scatterRd = normalize(vec3(rd.x, max(rd.y, 0.0), rd.z));

    vec3 transmittance;
    vec3 skyColor = GetAtmosphere(scatterRd, upVec, sunDir, moonDir, eyeAltitude, transmittance, SKY_LUT_STEPS, 4);

    float sunZenith = clamp(sunDir.y, 0.0, 1.0);
    vec3 noonGround = vec3(0.9, 0.95, 1.0) * sunZenith;
    vec3 groundColor = mix(skyColor * 0.4, noonGround, pow(sunZenith, 2.0));
    float horizon = smoothstep(-0.6, 0.05, rd.y);

    return mix(groundColor, skyColor, horizon);
}

vec3 getSky(vec3 rd, vec3 sunDir, vec3 moonDir, float eyeAltitude) {
    vec3 upVec = vec3(0.0, 1.0, 0.0);
    
    // Clamp view direction to horizon for scattering to avoid black nadir
    vec3 scatterRd = normalize(vec3(rd.x, max(rd.y, 0.0), rd.z));
    
    vec3 transmittance;
    vec3 skyColor = GetAtmosphere(scatterRd, upVec, sunDir, moonDir, eyeAltitude, transmittance, 4, 4);
    
    // Add Sun and Moon discs (only above horizon)
    if (rd.y > 0.0) {
        skyColor += getSunDisc(rd, sunDir, transmittance);
        skyColor += getMoonDisc(rd, moonDir, transmittance);
    }
    
    // Ground / Nadir blend:
    // At noon, the ground should be bright and white.
    // We blend from the horizon color to a brightened version for the ground.
    float sunZenith = clamp(sunDir.y, 0.0, 1.0);
    vec3 horizonColor = skyColor;
    
    // Calculate a "white" noon ground albedo based on sun height
    // We boost the brightness significantly for a clean "white" look at noon.
    vec3 noonGround = vec3(0.9, 0.95, 1.0) * sunZenith;
    vec3 groundColor = mix(horizonColor * 0.4, noonGround, pow(sunZenith, 2.0));
    
    float horizon = smoothstep(-0.6, 0.05, rd.y);
    
    return mix(groundColor, skyColor, horizon);
}
