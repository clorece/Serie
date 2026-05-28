#ifndef ATMOSPHERE_GLSL
#define ATMOSPHERE_GLSL

/*

*/

// --- Constants ---
#define SUN_ILLUMINANCE 10.0
#define MOON_ILLUMINANCE 0.05

#define SUN_COLOR_BASE (vec3(1.0, 0.9, 0.81) * SUN_ILLUMINANCE)
#define MOON_COLOR_BASE (vec3(0.25, 0.65, 1.0) * MOON_ILLUMINANCE)

#define PLANET_RADIUS 6371e3
#define ATMOSPHERE_HEIGHT 110e3
#define SCALE_HEIGHTS vec2(8.0e3, 1.2e3)

#define MIE_G 0.80

#define COEFF_RAYLEIGH vec3(5.8e-6, 1.35e-5, 3.31e-5)
#define COEFF_MIE vec3(3.0e-6, 3.0e-6, 3.0e-6)

#define AIR_NUMBER_DENSITY 2.5035422e25
#define OZONE_CONCENTRATION_PEAK 8e-6
#define OZONE_CROSS_SECTION vec3(2.0e-21, 6.0e-21, 2.0e-22)

const float pi = 3.14159265359;
const float rPI = 1.0 / pi;
const float rLOG2 = 1.0 / log(2.0);

const float OZONE_NUMBER_DENSITY = AIR_NUMBER_DENSITY * OZONE_CONCENTRATION_PEAK;
const vec3 COEFF_OZONE = (OZONE_CROSS_SECTION * (OZONE_NUMBER_DENSITY * 1.0e-6));

const vec2 INVERSE_SCALE_HEIGHTS = 1.0 / SCALE_HEIGHTS;
const vec2 SCALED_PLANET_RADIUS = PLANET_RADIUS * INVERSE_SCALE_HEIGHTS;
const float ATMOSPHERE_RADIUS = PLANET_RADIUS + ATMOSPHERE_HEIGHT;
const float ATMOSPHERE_RADIUS_SQUARED = ATMOSPHERE_RADIUS * ATMOSPHERE_RADIUS;

const mat3 COEFF_ATTENUATION = mat3(COEFF_RAYLEIGH, COEFF_MIE * 1.11, COEFF_OZONE);



vec2 GetRaySphereIntersection(vec3 position, vec3 direction, float radius) {
	float PoD = dot(position, direction);
	float radiusSquared = radius * radius;

	float delta = PoD * PoD + radiusSquared - dot(position, position);
	if (delta < 0.0) return vec2(-1.0);
	delta = sqrt(delta);

	return -PoD + vec2(-delta, delta);
}

float GetRayleighPhase(float cosTheta) {
	const vec2 mul_add = vec2(0.1, 0.28) * rPI;
	return cosTheta * mul_add.x + mul_add.y;
}

float GetMiePhase(float cosTheta, const float g) {
	float gg = g * g;
	return (gg * -0.25 + 0.25) * rPI * pow(-(2.0 * g) * cosTheta + (gg + 1.0), -1.5);
}

vec2 GetPhase(float cosTheta, const float g) {
	return vec2(GetRayleighPhase(cosTheta), GetMiePhase(cosTheta, g));
}

vec3 GetAtmosphereDensity(float centerDistance) {
	vec2 rayleighMie = exp(centerDistance * -INVERSE_SCALE_HEIGHTS + SCALED_PLANET_RADIUS);

	float ozone = exp(-max(0.0, (35000.0 - centerDistance) - PLANET_RADIUS) * (1.0 / 5000.0))
	            * exp(-max(0.0, (centerDistance - 35000.0) - PLANET_RADIUS) * (1.0 / 15000.0));
	
	return vec3(rayleighMie, ozone);
}

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

	// Planet intersection
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

	vec3 scatteringSun     = vec3(0.0);
	vec3 scatteringMoon    = vec3(0.0);
	transmittance = vec3(1.0);

	for (int i = 0; i < iSteps; ++i, position += increment) {
		vec3 density = GetAtmosphereDensity(length(position));

		vec3 stepAirmass      = density * stepSize;
		vec3 stepOpticalDepth = COEFF_ATTENUATION * stepAirmass;

		vec3 stepTransmittance       = exp2(-stepOpticalDepth * rLOG2);
		vec3 stepTransmFraction = clamp01((stepTransmittance - 1.0) / -max(stepOpticalDepth, 1e-7));
		vec3 stepScatteringVisible   = transmittance * stepTransmFraction;

		scatteringSun  += (stepAirmass.x * phaseSun.x * COEFF_RAYLEIGH + stepAirmass.y * phaseSun.y * COEFF_MIE) * stepScatteringVisible * GetAtmosphereTransmittance(position, sunVec,  jSteps);
		scatteringMoon += (stepAirmass.x * phaseMoon.x * COEFF_RAYLEIGH + stepAirmass.y * phaseMoon.y * COEFF_MIE) * stepScatteringVisible * GetAtmosphereTransmittance(position, moonVec, jSteps);

		transmittance *= stepTransmittance;
	}

	vec3 scattering = scatteringSun * SUN_COLOR_BASE + scatteringMoon * MOON_COLOR_BASE;

	scattering = pow(max(scattering, 0.0), vec3(1.0 / 1.35));

	return scattering;
}

#endif
