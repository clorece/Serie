#ifndef GI_GLSL
#define GI_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/voxelTrace.glsl"
// common.glsl provides isInShadow (used by GI_BOUNCE_SHADOWMAP)
#include "/lib/util/common.glsl"

#include "/lib/pt/ao.glsl"
#include "/lib/util/sampling.glsl"

// Shading for one GI ray. Traversal, sub-block geometry and emitter handling all
// live in voxelTrace.glsl now; this only turns a hit into radiance.
vec3 giRayRadiance(
    vec3 camPos, vec3 origin, vec3 dir, vec3 sunDir, vec3 sunColor, vec3 skyColor,
    out vec3 hitPos, out vec3 hitNormal, out bool wasHit, out uint hitCategory, out vec3 rayEmission,
    float skyLightmap
) {
    VoxelHit h = traceVoxelCascaded(origin, dir, float(GI_RADIUS), true);

    rayEmission = h.emission;

    // Blocklights wash out under an open midday sky.
    vec3 sunVec = normalize(sunPosition);
    vec3 upVec  = normalize(upPosition);
    float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
    float skyExposure = smoothstep(0.75, 0.9, skyLightmap);
    rayEmission *= mix(1.0, 0.05, sunUp * skyExposure);

    float skyOcc = max(skyLightmap, 0.0);

    if (h.hit) {
        wasHit      = true;
        hitCategory = h.category;
        vec3 rad = vec3(0.0);

        float ndl = max(dot(h.normal, sunDir), 0.0);
        if (ndl > 0.0 && skyOcc > 0.01) {
            #ifdef GI_BOUNCE_SHADOWMAP
                bool occluded = isInShadow(h.pos + h.normal * 0.1 - camPos);
            #else
                bool occluded = traceVoxelOccluded(h.pos + h.normal * 0.1, sunDir, float(GI_RADIUS), true);
            #endif
            if (!occluded) rad += h.albedo * sunColor * ndl * skyOcc;
        }

        vec3  skyProbeRaw   = h.normal + vec3(0.0, 1.0, 0.0);
        float skyProbeLenSq = dot(skyProbeRaw, skyProbeRaw);
        if (skyProbeLenSq > 1e-4 && skyOcc > 0.01) {
            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
            float lambertWeight = dot(h.normal, skyProbeDir);
            bool  skyEscape     = !traceVoxelOccluded(h.pos + h.normal * 0.15, skyProbeDir,
                                                      float(GI_SKY_PROBE_DIST), true);
            if (skyEscape) {
                rad += vec3(dot(h.albedo, vec3(0.2126, 0.7152, 0.0722)))
                     * skyColor * lambertWeight * GI_BOUNCE_SKY * skyOcc;
            }
        }

        hitPos    = h.pos;
        hitNormal = h.normal;
        return rad;
    }

    wasHit      = false;
    hitCategory = VOXEL_AIR;
    hitPos      = h.pos;
    hitNormal   = -dir;
    return skyColor * skyOcc * smoothstep(-0.2, 0.4, dir.y);
}

vec3 computeGI(
    vec3 worldPos, vec3 normal, inout uint seed, vec3 camPos,
    vec3 sunDir, vec3 sunColor, vec3 skyColor, float skyLightmap
) {
    vec3 origin = worldPos + normal * 0.1;
    vec3 acc    = vec3(0.0);

    for (int i = 0; i < GI_SAMPLES; i++) {
        vec3 dir = cosHemisphereDir(normal, randFloat(seed), randFloat(seed));
        vec3 hitPos, hitNormal, rayEmission;
        bool wasHit; uint hitCat;
        acc += giRayRadiance(camPos, origin, dir, sunDir, sunColor, skyColor,
                             hitPos, hitNormal, wasHit, hitCat, rayEmission, skyLightmap);
        acc += rayEmission;
    }
    return acc / float(GI_SAMPLES);
}

#endif
