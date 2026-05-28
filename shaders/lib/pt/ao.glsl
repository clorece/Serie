#ifndef AO_GLSL
#define AO_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/ddaTrace.glsl"



// Build an orthonormal tangent frame from a surface normal
void buildTBN(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

// Sample a cosine-weighted direction in the hemisphere oriented around n.
// r1, r2: uniform random numbers in [0, 1)
vec3 cosHemisphereDir(vec3 n, float r1, float r2) {
    float phi      = 2.0 * PI * r1;
    float sinTheta = sqrt(r2);        // cosine-weighted: pdf = cos(theta)/pi
    float cosTheta = sqrt(1.0 - r2);
    vec3 t, b;
    buildTBN(n, t, b);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + n * cosTheta);
}

// Cast RTAO_SAMPLES short cosine-weighted rays through the voxel atlas (NOT through
// the screen-space tracer — rays are short enough that they always stay in the grid)
// and return the unoccluded fraction in [0, 1]. 1 = fully lit, 0 = fully occluded.
// This is the per-frame RAW AO. Temporal accumulation happens in d0_accum (c9.a).
// Replaces the dedicated d5_gtao pass and its colortex12 storage.
float computeRTAO(
    usampler2D atlas,
    vec3        worldPos,
    vec3        normalWorld,
    inout uint  seed,
    vec3        camPos,
    sampler2D   depthtex0,
    mat4        gbufferProj,
    mat4        gbufferMV
) {
    vec3 origin = worldPos + normalWorld * 0.05;
    float unoccluded = 0.0;
    for (int i = 0; i < RTAO_SAMPLES; i++) {
        vec3 dir = cosHemisphereDir(normalWorld, randFloat(seed), randFloat(seed));
        if (!traceVoxelRay(atlas, origin, dir, float(RTAO_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV)) {
            unoccluded += 1.0;
        }
    }
    return unoccluded / float(RTAO_SAMPLES);
}

// Cast AO_SAMPLES short rays in the hemisphere of normalWorld and return
// the unoccluded fraction in [0, 1]. 1 = fully lit, 0 = fully occluded.
float computeAO(
    usampler2D atlas,
    vec3        worldPos,
    vec3        normalWorld,
    inout uint  seed,
    vec3        camPos,
    float       skyLightmap,
    sampler2D   depthtex0,
    mat4        gbufferProj,
    mat4        gbufferMV
) {
    // Offset slightly off the surface so the first voxel is the air above it
    vec3 origin = worldPos + normalWorld * 0.1;

    float unoccluded = 0.0;
    for (int i = 0; i < AO_SAMPLES; i++) {
        float r1  = randFloat(seed);
        float r2  = randFloat(seed);
        vec3  dir = cosHemisphereDir(normalWorld, r1, r2);
        if (!traceVoxelRay(atlas, origin, dir, float(AO_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV)) {
            unoccluded += 1.0;
        }
    }
    
    // Apply sky lightmap to prevent leaking in areas beyond the AO search radius
    return (unoccluded / float(AO_SAMPLES)) * sqrt(skyLightmap);
}

#endif
