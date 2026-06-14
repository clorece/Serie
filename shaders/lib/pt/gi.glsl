#ifndef GI_GLSL
#define GI_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/ddaTrace.glsl"
// common.glsl provides isInShadow (used by GI_BOUNCE_SHADOWMAP)
#include "/lib/util/common.glsl"

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

// Emission weight for a special-light voxel (category 100+mat) the ray is
// crossing. With VOXEL_EMISSIVE_SHAPES emission comes only from the material's
// emissive sub-box: if the ray stops on a shaped occluder (a torch post), it
// emits only when the hit point lands on the emissive region (the flame cap) and
// stays dark on the stick below -> the post casts a real shadow. Rays that pass
// the post emit when they cross the flame box. localRo/rayDir are in the voxel's
// local 0..1 frame (same as intersectVoxelShape); occT is the occluder hit dist.
float specialEmisFactor(uint mat, vec3 localRo, vec3 rayDir, bool realHit, float occT, bool hasShape) {
#ifdef VOXEL_EMISSIVE_SHAPES
    vec3 bmin, bmax;
    lightEmissiveAabb(mat, bmin, bmax);
    const float EB = 2.0 / 64.0; // edge tolerance (~0.03 block)
    if (realHit && hasShape) {
        vec3 hp = localRo + rayDir * occT; // where the ray meets the occluder shape
        bool onEmis = all(greaterThanEqual(hp, bmin - EB)) && all(lessThanEqual(hp, bmax + EB));
        return onEmis ? 1.0 : 0.0;         // flame cap glows, stick stays in shadow
    }
    float tn, tf;
    if (aabbEntry(localRo, rayDir, bmin, bmax, tn, tf)) return 1.0; // crosses / hits the flame box
    return realHit ? 1.0 : 0.0;            // full-cube emitter hit head-on
#else
    return realHit ? 1.0 : 0.35;
#endif
}

VoxelHit traceVoxelGI(usampler3D atlas, vec3 gridOrigin, vec3 worldPos, vec3 rayDir, float maxDist) {
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

    ivec3 lastBrick = ivec3(-1);
    for (int i = 0; i < GI_MAX_STEPS; i++) {
        if (tEntry > actualMaxDist) break;

        if (all(greaterThanEqual(vox, ivec3(0))) && all(lessThan(vox, VOXEL_DIMS))) {
            ivec3 curBrick = vox >> 3;
            if (curBrick != lastBrick) {
                if (texelFetch(superBrickSampler, vox >> 6, 0).r == 0u) {
                    vec3 cellMin = vec3((vox >> 6) << 6);
                    vec3 tb = (mix(cellMin, cellMin + float(VOXEL_SUPER), dirPos) - localPos) * invRayDir;
                    float tCellExit = min(tb.x, min(tb.y, tb.z));
                    lastMask = vec3(lessThanEqual(tb, vec3(tCellExit))); // entry face of the next cell
                    tEntry = tCellExit;
                    vox  = ivec3(floor(localPos + rayDir * (tCellExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;
                    first = false;
                    continue;
                }
                if (texelFetch(brickSampler, curBrick, 0).r == 0u) {
                    vec3 brickMin = vec3(curBrick << 3);
                    vec3 tb = (mix(brickMin, brickMin + float(VOXEL_BRICK), dirPos) - localPos) * invRayDir;
                    float tBrickExit = min(tb.x, min(tb.y, tb.z));
                    lastMask = vec3(lessThanEqual(tb, vec3(tBrickExit))); // entry face of the next brick
                    tEntry = tBrickExit;
                    vox  = ivec3(floor(localPos + rayDir * (tBrickExit + 1e-3)));
                    tMax = (vec3(vox) + max(vec3(stepDir), 0.0) - localPos) * invRayDir;
                    first = false;
                    continue;
                }
                lastBrick = curBrick; // occupied brick: skip re-tests until we leave it
            }
        }

        uvec4 v = texelFetch(atlas, vox, 0);
        if (v.r != VOXEL_AIR) {
            bool isEmis = (v.r == VOXEL_EMISSIVE || v.r >= 100u);
            #ifdef VOXEL_SHAPES
            uint shapeId = voxelShapeId(v.r);
            #else
            const uint shapeId = 0u;
            #endif

            if (shapeId == 0u && first) {
                if (isEmis) {
                    vec3 e = (v.r >= 100u) ? GetSpecialBlocklightColor(int(v.r - 100u)).rgb
                                           : vec3(v.gba) / 255.0;
                    if (isnan(e.r) || isnan(e.g) || isnan(e.b) || isinf(e.r) || isinf(e.g) || isinf(e.b)) {
                        e = vec3(0.0);
                    }
                    e = max(e, vec3(0.0));
                    r.emission += e * float(GI_EMISSION) * 0.35;
                }
            } else {
                bool  realHit = true;
                float tHit    = tEntry;
                vec3  nHit    = -vec3(stepDir) * lastMask; // face we entered through
                vec3  shapeRo = localPos - vec3(vox);      // ray origin in this voxel's local 0..1 frame
                float occT    = 0.0;                       // occluder hit distance in that local frame
                #ifdef VOXEL_SHAPES
                if (shapeId != 0u) {
                    realHit = intersectVoxelShape(shapeId, shapeRo, rayDir, first, tHit, nHit);
                    occT    = tHit;
                    if (!realHit) { tHit = tEntry; nHit = -vec3(stepDir) * lastMask; }
                }
                #endif

                if (isEmis) {
                    vec3 e = (v.r >= 100u) ? GetSpecialBlocklightColor(int(v.r - 100u)).rgb
                                           : vec3(v.gba) / 255.0;
                    if (isnan(e.r) || isnan(e.g) || isnan(e.b) || isinf(e.r) || isinf(e.g) || isinf(e.b)) {
                        e = vec3(0.0);
                    }
                    e = max(e, vec3(0.0));
                    float emisF = (v.r >= 100u) ? specialEmisFactor(v.r - 100u, shapeRo, rayDir, realHit, occT, shapeId != 0u)
                                                : (realHit ? 1.0 : 0.35); // simple emissive cube
                    r.emission += e * float(GI_EMISSION) * emisF;
                }

                if (realHit) {
                    r.hit      = true;
                    r.category = v.r;
                    r.albedo   = vec3(v.gba) / 255.0;
                    r.pos      = worldPos + rayDir * tHit;
                    r.normal   = nHit;
                    return r;
                }
            }
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
    usampler3D atlas, vec3 camPos, vec3 gridOrigin,
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
            #ifdef GI_BOUNCE_SHADOWMAP
                bool occluded = isInShadow(h.pos + h.normal * 0.1 - camPos);
            #else
                bool occluded = traceVoxelRay(atlas, h.pos + h.normal * 0.1, sunDir, float(GI_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV, false);
            #endif
            if (!occluded) rad += h.albedo * sunColor * ndl * skyOcc;
        }

        vec3  skyProbeRaw    = h.normal + vec3(0.0, 1.0, 0.0);
        float skyProbeLenSq  = dot(skyProbeRaw, skyProbeRaw);
        if (skyProbeLenSq > 1e-4 && skyOcc > 0.01) {
            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
            float lambertWeight = dot(h.normal, skyProbeDir);
            bool  skyEscape     = !traceVoxelRay(atlas, h.pos + h.normal * 0.15, skyProbeDir, float(GI_SKY_PROBE_DIST), camPos, depthtex0, gbufferProj, gbufferMV, false);
            vec3 probeSky = skyColor;
            if (skyEscape) rad += vec3(dot(h.albedo, vec3(0.2126, 0.7152, 0.0722))) * probeSky * lambertWeight * GI_BOUNCE_SKY * skyOcc;
        }

        hitPos    = h.pos;
        hitNormal = h.normal;
        return rad;
    }
    wasHit      = false;
    hitCategory = VOXEL_AIR;
    hitPos      = h.pos;
    hitNormal   = -dir;
    vec3 skyRad = skyColor * skyOcc;
    
    return skyRad * smoothstep(-0.2, 0.4, dir.y);
}


vec3 computeGI(
    usampler3D atlas, vec3 worldPos, vec3 normal, inout uint seed, vec3 camPos,
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
        acc += giRayRadiance(atlas, camPos, gridOrigin, origin, dir, sunDir, sunColor, skyColor, depthtex0, colortex5, colortex1, gbufferProj, gbufferMV, hitPos, hitNormal, wasHit, hitCat, rayEmission, skyLightmap, dither);
        acc += rayEmission;
    }
    return acc / float(GI_SAMPLES);
}

#endif
