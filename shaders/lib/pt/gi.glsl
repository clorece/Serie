#ifndef GI_GLSL
#define GI_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/ddaTrace.glsl"

#include "/lib/pt/ao.glsl"
#include "/lib/blocklightColors.glsl"

struct VoxelHit {
    bool  hit;
    vec3  pos;       // world-space entry point of the hit voxel
    vec3  normal;    // surface normal of the face the ray entered through
    uint  category;
    vec3  albedo;
    vec3  emission;  // emission gathered from non-occluding blocklights the ray passed through
};

VoxelHit traceVoxelGI(usampler2D atlas, vec3 gridOrigin, vec3 worldPos, vec3 rayDir, float maxDist) {
    VoxelHit r;
    r.hit = false; r.pos = worldPos; r.normal = vec3(0.0); r.category = VOXEL_AIR; r.albedo = vec3(0.0); r.emission = vec3(0.0);

    vec3  localPos = worldPos - gridOrigin;
    if (any(lessThan(localPos, vec3(0.0))) || any(greaterThanEqual(localPos, vec3(VOXEL_GRID_SIZE)))) {
        return r;
    }
    ivec3 vox      = ivec3(floor(localPos));
    ivec3 stepDir  = ivec3(sign(rayDir));
    vec3  tDelta   = abs(1.0 / (rayDir + 1e-8));

    vec3 t0Box = (vec3(0.0) - localPos) / (rayDir + 1e-8);
    vec3 t1Box = (vec3(VOXEL_GRID_SIZE) - localPos) / (rayDir + 1e-8);
    vec3 tMaxBox = max(t0Box, t1Box);
    float tExit = min(tMaxBox.x, min(tMaxBox.y, tMaxBox.z));
    float actualMaxDist = min(maxDist, tExit);

    vec3 tMax;
    for(int i=0; i<3; ++i) {
        if (rayDir[i] > 0.0) tMax[i] = (floor(localPos[i]) + 1.0 - localPos[i]) * tDelta[i];
        else if (rayDir[i] < 0.0) tMax[i] = (localPos[i] - floor(localPos[i])) * tDelta[i];
        else tMax[i] = 1e38;
    }

    vec3  lastMask = vec3(0.0);
    float tEntry   = 0.0;
    for (int i = 0; i < 80; i++) {
        if (tEntry > actualMaxDist) break;

        uvec4 v = texelFetch(atlas, voxelCoordToAtlas(vox), 0);
        if (i == 0) {
            if (v.r == VOXEL_EMISSIVE || v.r >= 100u) {
                vec3 e = (v.r >= 100u) ? GetSpecialBlocklightColor(int(v.r - 100u)).rgb
                                       : vec3(v.gba) / 255.0;
                if (isnan(e.r) || isnan(e.g) || isnan(e.b) || isinf(e.r) || isinf(e.g) || isinf(e.b)) {
                    e = vec3(0.0);
                }
                e = max(e, vec3(0.0));
                r.emission += e * float(GI_EMISSION) * 0.35;
            }
        } else if (v.r != VOXEL_AIR) {

            r.hit      = true;
            r.category = v.r;
            r.albedo   = vec3(v.gba) / 255.0;
            r.pos      = worldPos + rayDir * tEntry;
            r.normal   = -vec3(stepDir) * lastMask; // face we entered through


            if (v.r == VOXEL_EMISSIVE || v.r >= 100u) {
                vec3 e = (v.r >= 100u) ? GetSpecialBlocklightColor(int(v.r - 100u)).rgb
                                       : vec3(v.gba) / 255.0;
                if (isnan(e.r) || isnan(e.g) || isnan(e.b) || isinf(e.r) || isinf(e.g) || isinf(e.b)) {
                    e = vec3(0.0);
                }
                e = max(e, vec3(0.0));
                r.emission += e * float(GI_EMISSION);
            }
            return r;
        }

        bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
        lastMask = vec3(mask);
        tEntry   = min(tMax.x, min(tMax.y, tMax.z));
        tMax    += vec3(mask) * tDelta;
        vox     += stepDir * ivec3(mask);
    }
    r.pos = worldPos + rayDir * tEntry;
    return r;
}



vec3 giRayRadiance(
    usampler2D atlas, vec3 camPos, vec3 gridOrigin,
    vec3 origin, vec3 dir, vec3 sunDir, vec3 sunColor, vec3 skyColor,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV,
    out vec3 hitPos, out vec3 hitNormal, out bool wasHit, out uint hitCategory, out vec3 rayEmission,
    float skyLightmap, float dither
) {
    VoxelHit h = traceVoxelGI(atlas, gridOrigin, origin, dir, float(GI_RADIUS));

    rayEmission = h.emission;

    vec3 sunVec = normalize(sunPosition);
    vec3 upVec  = normalize(upPosition);
    float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
    float skyExposure = smoothstep(0.6, 0.9, skyLightmap);
    float blocklightSuppression = mix(1.0, 0.0, sunUp * skyExposure);
    rayEmission *= blocklightSuppression;


    float skyOcc = max(skyLightmap, 0.0);

    if (h.hit) {
        wasHit      = true;
        hitCategory = h.category;
        vec3 rad = vec3(0.0);

        float ndl = max(dot(h.normal, sunDir), 0.0);
        if (ndl > 0.0 && skyOcc > 0.01) {
            bool occluded = traceVoxelRay(atlas, h.pos + h.normal * 0.1, sunDir, float(GI_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV);
            if (!occluded) rad += h.albedo * sunColor * ndl * skyOcc;
        }

        vec3  skyProbeRaw    = h.normal + vec3(0.0, 1.0, 0.0);
        float skyProbeLenSq  = dot(skyProbeRaw, skyProbeRaw);
        if (skyProbeLenSq > 1e-4 && skyOcc > 0.01) {
            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
            float lambertWeight = dot(h.normal, skyProbeDir);
            bool  skyEscape     = !traceVoxelRay(atlas, h.pos + h.normal * 0.15, skyProbeDir, float(GI_SKY_PROBE_DIST), camPos, depthtex0, gbufferProj, gbufferMV);
            vec3 probeSky = skyColor;
            if (skyEscape) rad += h.albedo * probeSky * lambertWeight * GI_BOUNCE_SKY * skyOcc;
        }

        hitPos    = h.pos;
        hitNormal = h.normal;
        return rad;
    }
    
    vec3 ssrtHitNormal;
    vec2 ssrtHitUV;
    float remainingDist = max(0.0, float(GI_RADIUS) - distance(origin, h.pos));
    if (remainingDist > 0.0 && screenSpaceRayTrace(h.pos, dir, remainingDist, camPos, gbufferProj, gbufferMV, depthtex0, dither, ssrtHitUV, ssrtHitNormal, hitPos)) {
        wasHit = true;
        hitCategory = VOXEL_OPAQUE;
        hitNormal = ssrtHitNormal;
        

        vec3 ssgiColor = texture(colortex5, ssrtHitUV).rgb;
        if (isnan(ssgiColor.r) || isnan(ssgiColor.g) || isnan(ssgiColor.b) || isinf(ssgiColor.r) || isinf(ssgiColor.g) || isinf(ssgiColor.b)) {
            ssgiColor = vec3(0.0);
        }
        return max(ssgiColor, vec3(0.0));
    }

    wasHit      = false;
    hitCategory = VOXEL_AIR;
    hitPos      = h.pos;
    hitNormal   = -dir;
    vec3 skyRad = skyColor * skyOcc;
    
    return skyRad * smoothstep(-0.2, 0.4, dir.y);
}


vec3 computeGI(
    usampler2D atlas, vec3 worldPos, vec3 normal, inout uint seed, vec3 camPos,
    vec3 sunDir, vec3 sunColor, vec3 skyColor, float skyLightmap,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV
) {
    vec3 gridOrigin = floor(camPos) - vec3(VOXEL_RADIUS);
    vec3 origin = worldPos + normal * 0.1;
    vec3 acc    = vec3(0.0);

    for (int i = 0; i < GI_SAMPLES; i++) {
        float dither = randFloat(seed);
        vec3 dir = cosHemisphereDir(normal, randFloat(seed), randFloat(seed));
        vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCat; vec3 rayEmission;
        acc += giRayRadiance(atlas, camPos, gridOrigin, origin, dir, sunDir, sunColor, skyColor, depthtex0, colortex5, colortex1, gbufferProj, gbufferMV, hitPos, hitNormal, wasHit, hitCat, rayEmission, skyLightmap, dither);
        acc += rayEmission;
    }
    return acc / float(GI_SAMPLES);
}

#endif
