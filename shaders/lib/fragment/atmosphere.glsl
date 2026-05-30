#ifndef ATMOSPHERE_GLSL
#define ATMOSPHERE_GLSL

// Legacy per-pixel Bruneton-Nishita raymarched atmosphere.
// Kept temporarily so getSky() in sky.glsl works until Phase 1d wires the
// LUT-backed sampleSky() path. Constants + density + phase fns now live in
// atmosphereConstants.glsl and are shared with atmosphereLUT.glsl.

#include "/lib/fragment/atmosphereConstants.glsl"


vec3 GetAirmass(vec3 position, vec3 direction, float rayLength, const int steps) {
    float stepSize  = rayLength / float(steps);
    vec3  increment = direction * stepSize;
    position += increment * 0.5;

    vec3 airmass = vec3(0.0);
    for (int i = 0; i < steps; ++i, position += increment) {
        airmass += GetAtmosphereDensity(length(position));
    }

    return airmass * stepSize;
}

vec3 GetAtmosphereTransmittance(vec3 position, vec3 direction, const int steps) {
    float rayLength = dot(position, direction);
          rayLength = rayLength * rayLength + ATMOSPHERE_RADIUS_SQUARED - dot(position, position);
    if (rayLength < 0.0) return vec3(1.0);
          rayLength = sqrt(rayLength) - dot(position, direction);

    vec3 airmass = GetAirmass(position, direction, rayLength, steps);
    return exp2(-(COEFF_ATTENUATION * airmass) * rLOG2);
}

vec3 GetAtmosphere(
    vec3 nViewPos,
    vec3 upVec,
    vec3 sunVec,
    vec3 moonVec,
    float eyeAltitude,
    out vec3 transmittance,
    const int iSteps,
    const int jSteps
) {
    vec3 viewPos = (PLANET_RADIUS + eyeAltitude) * upVec;

    vec2 aid = GetRaySphereIntersection(viewPos, nViewPos, ATMOSPHERE_RADIUS);
    if (aid.y < 0.0) {
        transmittance = vec3(1.0);
        return vec3(0.0);
    }

    vec2 pid = GetRaySphereIntersection(viewPos, nViewPos, PLANET_RADIUS * 0.998);
    bool planetIntersected = pid.y >= 0.0;

    vec2 sd = vec2(
        (planetIntersected && pid.x < 0.0) ? pid.y : max(aid.x, 0.0),
        (planetIntersected && pid.x > 0.0) ? pid.x : aid.y
    );

    float stepSize  = (sd.y - sd.x) / float(iSteps);
    vec3  increment = nViewPos * stepSize;
    vec3  position  = nViewPos * sd.x + viewPos;
    position += increment * 0.34;

    vec2 phaseSun  = GetPhase(dot(nViewPos, sunVec ), MIE_G);
    vec2 phaseMoon = GetPhase(dot(nViewPos, moonVec), MIE_G);

    vec3 scatteringSun  = vec3(0.0);
    vec3 scatteringMoon = vec3(0.0);
    transmittance = vec3(1.0);

    for (int i = 0; i < iSteps; ++i, position += increment) {
        vec3 density = GetAtmosphereDensity(length(position));

        vec3 stepAirmass      = density * stepSize;
        vec3 stepOpticalDepth = COEFF_ATTENUATION * stepAirmass;

        vec3 stepTransmittance     = exp2(-stepOpticalDepth * rLOG2);
        vec3 stepTransmFraction    = clamp01((stepTransmittance - 1.0) / -max(stepOpticalDepth, 1e-7));
        vec3 stepScatteringVisible = transmittance * stepTransmFraction;

        scatteringSun  += (stepAirmass.x * phaseSun.x  * COEFF_RAYLEIGH + stepAirmass.y * phaseSun.y  * COEFF_MIE) * stepScatteringVisible * GetAtmosphereTransmittance(position, sunVec,  jSteps);
        scatteringMoon += (stepAirmass.x * phaseMoon.x * COEFF_RAYLEIGH + stepAirmass.y * phaseMoon.y * COEFF_MIE) * stepScatteringVisible * GetAtmosphereTransmittance(position, moonVec, jSteps);

        transmittance *= stepTransmittance;
    }

    vec3 scattering = scatteringSun * SUN_COLOR_BASE + scatteringMoon * MOON_COLOR_BASE;
    scattering = pow(max(scattering, 0.0), vec3(1.0 / 1.35));

    return scattering;
}

#endif
