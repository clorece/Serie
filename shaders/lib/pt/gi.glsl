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

VoxelHit traceVoxelGI(usampler3D atlas, sampler2D coarse, vec3 gridOrigin, vec3 worldPos, vec3 rayDir, float maxDist) {
    VoxelHit r;
    r.hit = false; r.pos = worldPos; r.normal = vec3(0.0); r.category = VOXEL_AIR; r.albedo = vec3(0.0); r.emission = vec3(0.0);

    vec3  localPos = worldPos - gridOrigin;
    if (any(lessThan(localPos, vec3(0.0))) || any(greaterThanEqual(localPos, vec3(VOXEL_DIMS)))) {
        return r;
    }
    ivec3 vox      = ivec3(floor(localPos));
    ivec3 stepDir  = ivec3(sign(rayDir));
    vec3  invRayDir = 1.0 / (rayDir + 1e-8);
    vec3  tDelta   = abs(invRayDir);
    vec3  dirPos   = step(0.0, rayDir); // 0/1 selector for the +/- exit face

    vec3 t0Box = (vec3(0.0) - localPos) * invRayDir;
    vec3 t1Box = (vec3(VOXEL_DIMS) - localPos) * invRayDir;
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
    bool  first    = true; // true until the first fine sample / skip (was `i == 0`)
    // generous cap; rays terminate far earlier via actualMaxDist / brick-skips
    for (int i = 0; i < GI_MAX_STEPS; i++) {
        if (tEntry > actualMaxDist) break;

        // --- brick-level empty-space skip ---
        // Empty bricks contain no occluders and no emissive voxels (emissive is
        // non-air), so jumping them never drops a hit or a glow tap.
        if (brickIsEmpty(coarse, vox)) {
            vec3 brickMin = vec3((vox >> 3) << 3);
            vec3 brickMax = brickMin + float(VOXEL_BRICK);
            vec3 tb = (mix(brickMin, brickMax, dirPos) - localPos) * invRayDir;
            float tBrickExit = min(tb.x, min(tb.y, tb.z));
            lastMask = vec3(lessThanEqual(tb, vec3(tBrickExit))); // entry face of the next brick
            tEntry = tBrickExit;
            vox  = ivec3(floor(localPos + rayDir * (tBrickExit + 1e-3)));
            tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;
            first = false;
            continue;
        }

        uvec4 v = texelFetch(atlas, vox, 0);
        if (first) {
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
        first    = false;
    }
    r.pos = worldPos + rayDir * tEntry;
    return r;
}



vec3 giRayRadiance(
    usampler3D atlas, sampler2D coarse, vec3 camPos, vec3 gridOrigin,
    vec3 origin, vec3 dir, vec3 sunDir, vec3 sunColor, vec3 skyColor,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV,
    out vec3 hitPos, out vec3 hitNormal, out bool wasHit, out uint hitCategory, out vec3 rayEmission,
    float skyLightmap, float dither
) {
    VoxelHit h = traceVoxelGI(atlas, coarse, gridOrigin, origin, dir, float(GI_RADIUS));

    rayEmission = h.emission;

    vec3 sunVec = normalize(sunPosition);
    vec3 upVec  = normalize(upPosition);
    float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
    float skyExposure = smoothstep(0.75, 0.9, skyLightmap);
    float blocklightSuppression = mix(1.0, 0.05, sunUp * skyExposure);
    rayEmission *= blocklightSuppression;


    float skyOcc = max(skyLightmap, 0.0);

    if (h.hit) {
        wasHit      = true;
        hitCategory = h.category;
        vec3 rad = vec3(0.0);

        float ndl = max(dot(h.normal, sunDir), 0.0);
        if (ndl > 0.0 && skyOcc > 0.01) {
            bool occluded = traceVoxelRay(atlas, coarse, h.pos + h.normal * 0.1, sunDir, float(GI_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV, false);
            if (!occluded) rad += h.albedo * sunColor * ndl * skyOcc;
        }

        vec3  skyProbeRaw    = h.normal + vec3(0.0, 1.0, 0.0);
        float skyProbeLenSq  = dot(skyProbeRaw, skyProbeRaw);
        if (skyProbeLenSq > 1e-4 && skyOcc > 0.01) {
            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
            float lambertWeight = dot(h.normal, skyProbeDir);
            bool  skyEscape     = !traceVoxelRay(atlas, coarse, h.pos + h.normal * 0.15, skyProbeDir, float(GI_SKY_PROBE_DIST), camPos, depthtex0, gbufferProj, gbufferMV, false);
            vec3 probeSky = skyColor;
            // Use luminance-only albedo — skylight is too diffuse/weak
            // to produce visible color bleeding off surfaces.
            if (skyEscape) rad += vec3(dot(h.albedo, vec3(0.2126, 0.7152, 0.0722))) * probeSky * lambertWeight * GI_BOUNCE_SKY * skyOcc;
        }

        hitPos    = h.pos;
        hitNormal = h.normal;
        return rad;
    }
    
    // Voxel ray missed everything within the grid → sky. (The old screen-space
    // GI fallback here is removed: with the radius-256 voxel grid the voxel pass
    // is the source of truth; screen-space ray tracing is kept only for RTAO.)
    wasHit      = false;
    hitCategory = VOXEL_AIR;
    hitPos      = h.pos;
    hitNormal   = -dir;
    vec3 skyRad = skyColor * skyOcc;
    
    return skyRad * smoothstep(-0.2, 0.4, dir.y);
}


vec3 computeGI(
    usampler3D atlas, sampler2D coarse, vec3 worldPos, vec3 normal, inout uint seed, vec3 camPos,
    vec3 sunDir, vec3 sunColor, vec3 skyColor, float skyLightmap,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV
) {
    vec3 gridOrigin = floor(camPos) - VOXEL_RADIUS_VEC;
    vec3 origin = worldPos + normal * 0.1;
    vec3 acc    = vec3(0.0);

    for (int i = 0; i < GI_SAMPLES; i++) {
        float dither = randFloat(seed);
        vec3 dir = cosHemisphereDir(normal, randFloat(seed), randFloat(seed));
        vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCat; vec3 rayEmission;
        acc += giRayRadiance(atlas, coarse, camPos, gridOrigin, origin, dir, sunDir, sunColor, skyColor, depthtex0, colortex5, colortex1, gbufferProj, gbufferMV, hitPos, hitNormal, wasHit, hitCat, rayEmission, skyLightmap, dither);
        acc += rayEmission;
    }
    return acc / float(GI_SAMPLES);
}

#endif
