#ifndef AO_GLSL
#define AO_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/ddaTrace.glsl"

void buildTBN(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}


vec3 cosHemisphereDir(vec3 n, float r1, float r2) {
    float phi      = 2.0 * PI * r1;
    float sinTheta = sqrt(r2);        // cosine-weighted: pdf = cos(theta)/pi
    float cosTheta = sqrt(1.0 - r2);
    vec3 t, b;
    buildTBN(n, t, b);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + n * cosTheta);
}

// (computeRTAO removed — ambient occlusion is now the screen-space GTAO in
// lib/pt/gtao.glsl, computed in d0_accum, fully decoupled from the voxel
// tracer. computeAO below remains for the legacy VOXEL_AO mode.)

float computeAO(
    usampler3D atlas,
    vec3        worldPos,
    vec3        normalWorld,
    inout uint  seed,
    vec3        camPos,
    float       skyLightmap,
    sampler2D   depthtex0,
    mat4        gbufferProj,
    mat4        gbufferMV
) {
    // offset slightly off the surface so the first voxel is the air above it
    vec3 origin = worldPos + normalWorld * 0.1;
    if (normalWorld.y > 0.5) {
        origin.y = max(origin.y, floor(worldPos.y - 0.01) + 1.10);
    }

    float unoccluded = 0.0;
    for (int i = 0; i < AO_SAMPLES; i++) {
        float r1  = randFloat(seed);
        float r2  = randFloat(seed);
        vec3  dir = cosHemisphereDir(normalWorld, r1, r2);
        if (!traceVoxelRay(atlas, origin, dir, float(AO_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV, false)) {
            unoccluded += 1.0;
        }
    }
    
    // apply sky lightmap to prevent leaking in areas beyond the AO search radius
    return (unoccluded / float(AO_SAMPLES)) * sqrt(skyLightmap);
}

#endif
