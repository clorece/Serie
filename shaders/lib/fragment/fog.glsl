#include "/lib/fragment/atmosphere.glsl"

vec3 getFog(vec3 rd, float distBlocks, vec3 sunDir, vec3 moonDir, float eyeAltitude, vec3 color) {
    vec3 upVec = vec3(0.0, 1.0, 0.0);
    
    // Scale blocks to meters (1 block = 1m)
    // GetAtmosphere uses meters for stepSize (PLANET_RADIUS is in meters)
    float distMeters = distBlocks;
    
    vec3 transmittance;
    // Compute the scattering over the finite distance to the fragment.
    vec3 skyColor = getSky(rd, sunDir, moonDir, eyeAltitude);
    
    float fogDensity = 0.002;
    float fogFactor = exp(-distBlocks * fogDensity);
    
    return mix(skyColor, color, clamp(fogFactor, 0.0, 1.0));
}
